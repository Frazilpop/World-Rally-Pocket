// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally (Pocket) — whole-board harness, after World Rally 2 Pocket's.
//
//   tb_wrally <set.rom> <frames> <outdir> [dump frames, comma list]
//       [--rom-lat N] [--trace file] [--trace-count N] [--trace-from F]
//       [--mcu-trace file] [--data-only] [--inputs plan.txt] [--dsw hex]
//       [--release N] [--gen-dir dir] [--ticks file] [--audio file]
//       [--wlog file] [--mem-dump frames] [--scene dumpdir]
//
// Hosts wrally_board the way the Pocket shell does, with a behavioural
// SDRAM: the .rom image on five independent line ports, fixed latency
// (--rom-lat, 48 MHz clocks). Optimistic: no contention, no refresh. It
// answers "does the board work", not "does it fit the bandwidth". Built
// with SDR=real (sim/wrally/build.sh), the shell's own controller times the
// lines instead (sim/wrally/sdr_timing.sv: kaneko_sdram_x2, kaneko_sdram,
// sdram_model, the read-back port asking once a frame) and --rom-lat is
// ignored; the data still comes from the image.
//
// The loader snoop is fed the ds5002 slot before reset is released, as the
// Pocket's loader passes it. The CPUs are then released --release clocks
// after the video's vblank (default 0): IRQ 6 is the board's own, counted
// in 68000 clocks from reset (IRQ_FIRST in sim/wrally/build.sh), so this
// only places the picture against it.
//
// --trace writes the 68000's bus cycles in tools/mame_wrally_bus_trace.lua's
// format, one line per cycle as it ends (IACK cycles left out, as MAME has
// none), with "# frame N" at each vblank IRQ. --mcu-trace (default: the
// trace's name + ".mcu") writes the DS5002FP's MOVX accesses to the shared
// RAM, "<n68k> <t12> <addr> <R|W> <data>", as the Lua script does.
// --trace-from F starts both at frame F's IRQ ("# frame F" first), as the Lua
// script's BUS_TRACE_FROM. --data-only leaves the program ROM's reads out but
// for the autovectors (000060-00007f), as BUS_TRACE_DATA_ONLY. --ticks: the 68000 clock (board time since
// release) at the end of each traced access, one line each, and
// "# irq <clock>" at each IRQ 6.
//
// Writes frame_NNNNN.ppm (368 x 232) for each requested frame and one line
// a frame to stats.csv: the video line IRQ 6 fell on (232 = vblank's first),
// the most board time owed in the frame (ticks; 4095 = the credit full,
// ticks dropped), the ticks lost and each port's longest wait. At the end:
// the sprite engine's longest line in 48 MHz clocks (of the line's 3,077),
// and the lines it had not finished when the next began, with the lowest
// sprite it had reached on one (511 the last; MAME draws all 511 on every
// line).
// --wlog writes every 68000 write to the VRAM, the vregs, the palette and the
// sprite RAM with the video line and pixel it landed on and the word stored
// after it (the VRAM's decrypted; 0 for the IRQ clear):
// "<frame> <line> <pixel> <addr> <data> <mask> <stored>".
// --mem-dump N,M,... writes vram_NNNNN.bin, palette_NNNNN.bin,
// spriteram_NNNNN.bin and vregs_NNNNN.bin at frame N's IRQ, as
// tools/mame_wrally_dump.lua's vram.bin, palette.bin, spriteram.bin and
// vregs.bin at its notifier N (little-endian words; the VRAM decrypted):
// shadows kept from the 68000's writes, the VRAM's with the word jlrh's
// decryption made of each.
// --scene draws a MAME dump (tools/mame_wrally_dump.lua: vram.bin,
// palette.bin, spriteram.bin, vregs.bin) instead of running the game:
// board time paused from release, the dump written into the VRAM, the
// palette, the sprite RAM and the vregs, and `frames` counted in video
// frames; frame 3 on is the dump's picture, to set against its screen.png.
// --audio writes the OKI's samples (jt6295's 48 kHz strobe) as raw signed
// 16-bit little-endian mono.

#include "Vwrally_board.h"
#include "Vwrally_board___024root.h"
#include "verilated.h"
#ifdef SDR_REAL
#include "Vsdr_timing.h"
#endif

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

static const int NP = 5;
static const int SDR_AW = 25;
static const int W = 368, H = 232;

template <typename T>
static uint64_t getbits(const T& w, int lo, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((w[b >> 5] >> (b & 31)) & 1) v |= 1ull << i;
    }
    return v;
}
template <typename T>
static void setbits(T& w, int lo, int n, uint64_t v) {
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((v >> i) & 1) w[b >> 5] |= (1u << (b & 31));
        else              w[b >> 5] &= ~(1u << (b & 31));
    }
}

static std::string absolute(const char* p) {
    if (!p) return "";
    if (p[0] == '/') return p;
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) return p;
    return std::string(cwd) + "/" + p;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s set.rom frames outdir [dumps] [--rom-lat N] [--trace f] "
                        "[--trace-count N] [--trace-from F] [--mcu-trace f] [--data-only] [--inputs plan] "
                        "[--dsw hex] [--release N] [--gen-dir d] [--ticks f] [--audio f] [--wlog f]\n", argv[0]);
        return 2;
    }
    std::string rom_path = absolute(argv[1]);
    int frames = atoi(argv[2]);
    std::string outdir = absolute(argv[3]);
    std::set<int> dumps, mem_dumps;
    int rom_lat = 10;
    std::string trace_path, mcu_path, ticks_path, inputs_path, audio_path, wlog_path, scene_dir, gen_dir = absolute("build/gen");
    long trace_count = 0;
    int trace_from = 0;
    bool data_only = false;
    unsigned dsw = 0xffdf;
    long long release = 0;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc)          rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)       trace_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--trace-count") && i + 1 < argc) trace_count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace-from") && i + 1 < argc)  trace_from = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mcu-trace") && i + 1 < argc)   mcu_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--ticks") && i + 1 < argc)       ticks_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--data-only"))                   data_only = true;
        else if (!strcmp(argv[i], "--inputs") && i + 1 < argc)      inputs_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--dsw") && i + 1 < argc)         dsw = strtoul(argv[++i], 0, 16);
        else if (!strcmp(argv[i], "--release") && i + 1 < argc)     release = atoll(argv[++i]);
        else if (!strcmp(argv[i], "--gen-dir") && i + 1 < argc)     gen_dir = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--audio") && i + 1 < argc)       audio_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--wlog") && i + 1 < argc)        wlog_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--scene") && i + 1 < argc)       scene_dir = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--mem-dump") && i + 1 < argc) {
            std::string s = argv[++i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) mem_dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
        else {
            std::string s = argv[i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
    }
    if (!trace_path.empty() && mcu_path.empty()) mcu_path = trace_path + ".mcu";
    mkdir(outdir.c_str(), 0755);

    // -------------------------------------------------------------- memories
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(rom_path.c_str(), "rb");
        if (!f) { perror(rom_path.c_str()); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n);
        if (fread(rom.data(), 1, n, f) != (size_t)n) { perror("read"); return 1; }
        fclose(f);
    }
    rom.resize(64u << 20, 0);
    auto rom_word = [&](uint32_t w) -> uint16_t {
        return (uint16_t)rom[2 * w] | ((uint16_t)rom[2 * w + 1] << 8);
    };

    // fx68k's and jt8051's $readmem files are relative: run from there.
    if (chdir(gen_dir.c_str()) != 0) { perror(gen_dir.c_str()); return 1; }

    Verilated::commandArgs(argc, argv);
    Vwrally_board* t = new Vwrally_board;
    auto& R = *t->rootp;

    t->rst = 1; t->rom_loaded = 0;
    t->p1 = 0; t->p2 = 0; t->coin = 0; t->start = 0; t->service = 0; t->test = 0;
    t->dsw = dsw;
    t->pause = 0;
    t->dl_wr = 0;

    uint64_t cyc = 0;
    // One 48 MHz clock
    auto tick = [&]() {
        t->clk = 1; t->eval();
        t->clk = 0; t->eval();
        cyc++;
    };

    // ----------------------------------------------------------- ROM ports
    struct Port { int busy = 0; int cnt = 0; uint32_t addr = 0; };
    Port rp[NP];
    // The longest wait on each port, request to acknowledge, in 48 MHz
    // clocks, this frame
    int w_cnt[NP] = {0}, w_max[NP] = {0};
    auto count_waits = [&](uint32_t req, uint32_t ack) {
        for (int p = 0; p < NP; p++) {
            if ((req >> p) & 1) { w_cnt[p]++; if (w_cnt[p] > w_max[p]) w_max[p] = w_cnt[p]; }
            if ((ack >> p) & 1) w_cnt[p] = 0;
        }
    };
#ifdef SDR_REAL
    Vsdr_timing* sd = new Vsdr_timing;
    sd->rst_n = 0; sd->s_req = 0;
    for (int i = 0; i < 8; i++) { sd->clk_fast = 1; sd->eval(); sd->clk_fast = 0; sd->eval(); }
    sd->rst_n = 1;
    bool rb_want = false;           // the read-back port's once-a-frame request
    auto serve_rom = [&]() {
        uint32_t req = t->rom_req;
        uint32_t sreq = req | (rb_want ? 1u << NP : 0);
        sd->s_req = sreq;
        for (int p = 0; p < NP; p++)
            setbits(sd->s_addr, p * SDR_AW, SDR_AW, getbits(t->rom_addr, p * SDR_AW, SDR_AW));
        setbits(sd->s_addr, NP * SDR_AW, SDR_AW, 0);
        uint32_t ack = 0;
        for (int k = 0; k < 2; k++) {
            sd->clk_fast = 1; sd->eval();
            sd->clk_fast = 0; sd->eval();
            ack |= sd->s_ack;
        }
        if ((ack >> NP) & 1) rb_want = false;
        ack &= (1u << NP) - 1;
        for (int p = 0; p < NP; p++) if ((ack >> p) & 1) {
            uint32_t w = (uint32_t)getbits(t->rom_addr, p * SDR_AW, SDR_AW) & ~3u;
            for (int k = 0; k < 4; k++)
                setbits(t->rom_dout, p * 64 + k * 16, 16, rom_word(w + k));
        }
        count_waits(req, ack);
        t->rom_ack = ack;
    };
#else
    auto serve_rom = [&]() {
        uint32_t req = t->rom_req;
        uint32_t ack = 0;
        for (int p = 0; p < NP; p++) {
            Port& P = rp[p];
            if (!P.busy && ((req >> p) & 1)) {
                P.busy = 1; P.cnt = rom_lat;
                P.addr = (uint32_t)getbits(t->rom_addr, p * SDR_AW, SDR_AW);
            }
            if (P.busy && --P.cnt <= 0) {
                ack |= 1u << p;
                uint32_t w = P.addr & ~3u;
                for (int k = 0; k < 4; k++)
                    setbits(t->rom_dout, p * 64 + k * 16, 16, rom_word(w + k));
                P.busy = 0;
            }
        }
        count_waits(req, ack);
        t->rom_ack = ack;
    };
#endif

    // Power-on: a few clocks of reset, then the ds5002 slot through the snoop
    // (every other clock, as the board asks), video running throughout.
    for (int i = 0; i < 16; i++) tick();
    t->rst = 0;
    for (uint32_t w = 0x80000; w < 0x84000; w++) {
        t->dl_wr = 1; t->dl_addr = w; t->dl_data = rom_word(w);
        tick();
        t->dl_wr = 0;
        tick();
    }
    // Release the CPUs `release` clocks after a vblank IRQ.
    {
        bool seen = false;
        uint64_t at = 0;
        while (!seen) { tick(); if (R.wrally_board__DOT__dbg_vbirq) { seen = true; at = cyc; } }
        while (cyc < at + (uint64_t)release) tick();
    }
    const bool scene = !scene_dir.empty();
    if (scene) t->pause = 1;
    t->rom_loaded = 1;
    if (scene) {
        auto load = [&](const char* name, int sel, int words) {
            std::vector<uint8_t> d(words * 2, 0);
            FILE* f = fopen((scene_dir + "/" + name).c_str(), "rb");
            if (!f) { perror(name); exit(1); }
            size_t n = fread(d.data(), 1, d.size(), f);
            fclose(f);
            for (int w = 0; w < (int)(n / 2); w++) {
                uint16_t v = d[2 * w] | (d[2 * w + 1] << 8);
                if (sel < 3) {
                    R.wrally_board__DOT__u_vmem__DOT__sc_we = 1;
                    R.wrally_board__DOT__u_vmem__DOT__sc_sel = sel;
                    R.wrally_board__DOT__u_vmem__DOT__sc_addr = w;
                    R.wrally_board__DOT__u_vmem__DOT__sc_data = v;
                } else {
                    R.wrally_board__DOT__u_main__DOT__sc_vwe = 1;
                    R.wrally_board__DOT__u_main__DOT__sc_vsel = w;
                    R.wrally_board__DOT__u_main__DOT__sc_vdata = v;
                }
                tick();
            }
            R.wrally_board__DOT__u_vmem__DOT__sc_we = 0;
            R.wrally_board__DOT__u_main__DOT__sc_vwe = 0;
        };
        load("vram.bin", 0, 0x2000);
        load("palette.bin", 1, 0x2000);
        load("spriteram.bin", 2, 0x800);
        load("vregs.bin", 3, 4);
        fprintf(stderr, "scene %s loaded\n", scene_dir.c_str());
    }
    const uint64_t cyc0 = cyc;
    fprintf(stderr, "CPUs released at clock %llu\n", (unsigned long long)cyc0);

    // ------------------------------------------------------------ inputs
    // One line a frame, "<frame> coin=1 start=1 b1=1 right=0 ...". Line n is
    // applied at vblank IRQ n + 1, counting from release: tools/mame_wrally_
    // inputs.lua sets frame n's inputs in MAME's notifier n, and MAME's ports
    // take them at their next frame update, so the 68000 first reads them
    // after vblank n + 1 (the race's start, pressed at 700, is read from
    // frame 701).
    struct Step { int frame; std::string name; int val; };
    std::vector<Step> plan;
    size_t plan_i = 0;
    if (!inputs_path.empty()) {
        FILE* f = fopen(inputs_path.c_str(), "r");
        if (!f) { perror(inputs_path.c_str()); return 1; }
        char line[512];
        while (fgets(line, sizeof line, f)) {
            char* save = nullptr;
            char* tok = strtok_r(line, " \t\r\n", &save);
            if (!tok || tok[0] == '#') continue;
            int fr = atoi(tok);
            while ((tok = strtok_r(nullptr, " \t\r\n", &save))) {
                char* eq = strchr(tok, '=');
                if (!eq) continue;
                *eq = 0;
                plan.push_back({fr, tok, atoi(eq + 1)});
            }
        }
        fclose(f);
        fprintf(stderr, "inputs: %zu steps from %s\n", plan.size(), inputs_path.c_str());
    }
    uint8_t p1v = 0;
    auto apply_inputs = [&](int fr) {
        while (plan_i < plan.size() && plan[plan_i].frame <= fr) {
            const Step& st = plan[plan_i++];
            int bit = -1;
            // p1 = {b2, b1, up, down, left, right}
            if      (st.name == "right") bit = 0;
            else if (st.name == "left")  bit = 1;
            else if (st.name == "down")  bit = 2;
            else if (st.name == "up")    bit = 3;
            else if (st.name == "b1")    bit = 4;
            else if (st.name == "b2")    bit = 5;
            else if (st.name == "coin")    { t->coin    = st.val ? 1 : 0; continue; }
            else if (st.name == "start")   { t->start   = st.val ? 1 : 0; continue; }
            else if (st.name == "test")    { t->test    = st.val ? 1 : 0; continue; }
            else if (st.name == "service") { t->service = st.val ? 1 : 0; continue; }
            else if (st.name == "pause")   { t->pause   = st.val ? 1 : 0; continue; }
            if (bit >= 0) {
                if (st.val) p1v |= (1u << bit); else p1v &= ~(1u << bit);
                t->p1 = p1v;
            }
        }
    };
    apply_inputs(0);

    // ------------------------------------------------------------ traces
    FILE* trace = trace_path.empty() ? nullptr : fopen(trace_path.c_str(), "w");
    FILE* mtrace = (trace && mcu_path != "none") ? fopen(mcu_path.c_str(), "w") : nullptr;
    long traced = 0, mtraced = 0;
    bool tracing = trace_from <= 0;
    auto traced_addr = [&](uint32_t a) {
        return !data_only || a >= 0x100000 || (a >= 0x60 && a < 0x80);
    };
    FILE* ticks = ticks_path.empty() ? nullptr : fopen(ticks_path.c_str(), "w");
    uint64_t bclk = 0;
    // the 68000: the bus cycle's last clock before AS rises
    bool as_prev = false;
    uint32_t c_addr = 0, c_data = 0, c_mask = 0, c_dec = 0; bool c_rd = false;
    // the video memories as the 68000 wrote them (--mem-dump)
    std::vector<uint16_t> sh_vram(0x2000, 0), sh_pal(0x2000, 0), sh_spr(0x800, 0), sh_vregs(4, 0);
    auto shadow = [&](std::vector<uint16_t>& m, uint32_t i, uint32_t d) {
        m[i] = (m[i] & ~c_mask) | (d & c_mask);
    };
    auto mem_dump = [&](int n) {
        auto put = [&](const char* name, const std::vector<uint16_t>& m) {
            char fn[1024];
            snprintf(fn, sizeof fn, "%s/%s_%05d.bin", outdir.c_str(), name, n);
            FILE* f = fopen(fn, "wb");
            for (uint16_t w : m) { uint8_t b[2] = { (uint8_t)w, (uint8_t)(w >> 8) }; fwrite(b, 1, 2, f); }
            fclose(f);
        };
        put("vram", sh_vram); put("palette", sh_pal); put("spriteram", sh_spr); put("vregs", sh_vregs);
    };
    // the DS5002: an access is a run of clocks with the same address and
    // direction. A read is written with the byte jt8051 took (dbg_x_take),
    // which may be on a clock after the access: until then it waits.
    bool x_prev = false; uint32_t x_addr = 0; bool x_wr = false; uint32_t x_data = 0;
    uint64_t x_start = 0; long x_n68 = 0; bool x_took = false;
    struct XRec { long n68; uint64_t t; uint32_t a; bool wr; uint32_t d; };
    bool x_pend = false; XRec x_rec{};
    auto mcu_write = [&](const XRec& r) {
        fprintf(mtrace, "%ld %llu %05x %c %02x\n", r.n68, (unsigned long long)r.t, r.a,
                r.wr ? 'W' : 'R', r.d & 0xff);
        mtraced++;
    };
    auto mcu_flush = [&]() {
        if (!mtrace || !tracing) return;
        if (x_pend) { mcu_write(x_rec); x_pend = false; }
        XRec r{x_n68, x_start, x_addr, x_wr, x_data};
        if (x_wr || x_took) mcu_write(r);
        else { x_rec = r; x_pend = true; }
    };

    // ------------------------------------------------------------- video
    std::vector<uint8_t> img(W * H * 3, 0);
    int x = 0, y = 0, frame = 0;
    int prev_hb = 1, prev_vb = 1;
    FILE* stats = fopen((outdir + "/stats.csv").c_str(), "w");
    fprintf(stats, "frame,cycles,bus_cycles,mcu_accesses,irq_line,owed_max,lost,wait0,wait1,wait2,wait3,wait4\n");
    int wait_all[NP] = {0};
    long lost = 0, lost_all = 0;
    int owed_max = 0;
    FILE* audio = audio_path.empty() ? nullptr : fopen(audio_path.c_str(), "wb");
    FILE* wlog = wlog_path.empty() ? nullptr : fopen(wlog_path.c_str(), "w");
    long audio_n = 0;
    uint64_t bus_cycles = 0, bus_cycles_f = 0;
    long mcu_f = 0;
    bool irq_prev = false;
    long spr_len = 0, spr_max = 0, spr_cut = 0, spr_cut_at = 512;

    while (frame < frames) {
        serve_rom();
        tick();
        // ---- the sprite engine's line
        if (R.wrally_board__DOT__dbg_spr_start) {
            if (R.wrally_board__DOT__dbg_spr_busy) {
                spr_cut++;
                long at = (R.wrally_board__DOT__dbg_spr_idx - 3) / 4;
                if (at < spr_cut_at) spr_cut_at = at;
            }
            spr_len = 0;
        } else if (R.wrally_board__DOT__dbg_spr_busy && ++spr_len > spr_max) spr_max = spr_len;
        if (audio && t->snd_sample) {
            int16_t s = (int16_t)t->snd;
            fwrite(&s, 2, 1, audio);
            audio_n++;
        }
        bclk += R.wrally_board__DOT__dbg_cen;
        if ((int)t->diag_owed > owed_max) owed_max = t->diag_owed;
        lost += R.wrally_board__DOT__dbg_lost;
        if (ticks && R.wrally_board__DOT__dbg_irq) fprintf(ticks, "# irq %llu\n", (unsigned long long)bclk);

        // ---- 68000 bus monitor
        {
            bool as = R.wrally_board__DOT__dbg_as;
            if (as) {
                c_addr = (uint32_t)R.wrally_board__DOT__dbg_eab << 1;
                c_rd   = R.wrally_board__DOT__dbg_rw;
                uint32_t ds = R.wrally_board__DOT__dbg_ds;
                c_mask = (ds == 3) ? 0xffff : (ds == 2) ? 0xff00 : (ds == 1) ? 0x00ff : 0;
                c_data = c_rd ? R.wrally_board__DOT__dbg_din : R.wrally_board__DOT__dbg_dout;
                c_dec  = R.wrally_board__DOT__dbg_vdec;
            }
            if (!as && as_prev) {
                bus_cycles++;
                uint32_t stored = 0;
                if (!c_rd && c_mask) {
                    std::vector<uint16_t>* m = nullptr; uint32_t i = 0, d = c_data;
                    if (c_addr >= 0x100000 && c_addr < 0x104000) { m = &sh_vram; i = (c_addr >> 1) & 0x1fff; d = c_dec; }
                    else if (c_addr >= 0x108000 && c_addr < 0x108008) { m = &sh_vregs; i = (c_addr >> 1) & 3; }
                    else if (c_addr >= 0x200000 && c_addr < 0x204000) { m = &sh_pal; i = (c_addr >> 1) & 0x1fff; }
                    else if (c_addr >= 0x440000 && c_addr < 0x441000) { m = &sh_spr; i = (c_addr >> 1) & 0x7ff; }
                    if (m) { shadow(*m, i, d); stored = (*m)[i]; }
                }
                if (wlog && !c_rd && c_mask &&
                    ((c_addr >= 0x100000 && c_addr < 0x108010) || (c_addr >= 0x200000 && c_addr < 0x204000) ||
                     (c_addr >= 0x440000 && c_addr < 0x441000)))
                    fprintf(wlog, "%d %d %d %06x %04x %04x %04x\n", frame,
                            (int)R.wrally_board__DOT__dbg_vcnt, (int)R.wrally_board__DOT__dbg_hcnt,
                            c_addr, c_data & c_mask, c_mask, stored);
                if (trace && tracing && c_mask && traced_addr(c_addr)) {
                    fprintf(trace, "%06x %c %04x %04x\n", c_addr, c_rd ? 'R' : 'W', c_data & c_mask, c_mask);
                    traced++;
                    if (ticks) fprintf(ticks, "%llu\n", (unsigned long long)bclk);
                    if (trace_count > 0 && traced >= trace_count) {
                        fclose(trace); trace = nullptr;
                        if (mtrace) { fclose(mtrace); mtrace = nullptr; }
                    }
                }
            }
            as_prev = as;
        }
        // ---- DS5002 MOVX monitor
        {
            bool acc = R.wrally_board__DOT__dbg_x_rd || R.wrally_board__DOT__dbg_x_wr;
            uint32_t a = R.wrally_board__DOT__dbg_x_addr;
            bool wr = R.wrally_board__DOT__dbg_x_wr;
            if (x_prev && (!acc || a != x_addr || wr != x_wr)) mcu_flush();
            if (acc && (!x_prev || a != x_addr || wr != x_wr)) {
                x_addr = a; x_wr = wr; x_start = bclk; x_n68 = traced; x_took = false;
            }
            bool take = R.wrally_board__DOT__dbg_x_take;
            if (acc && wr) x_data = R.wrally_board__DOT__dbg_x_dout;
            if (acc && !wr && !x_took) x_data = R.wrally_board__DOT__dbg_x_din;
            if (take && acc && !wr) { x_data = R.wrally_board__DOT__dbg_x_din; x_took = true; }
            else if (take && x_pend) {
                x_rec.d = R.wrally_board__DOT__dbg_x_din;
                if (mtrace && tracing) mcu_write(x_rec);
                x_pend = false;
            }
            x_prev = acc;
        }

        // ---- frames: MAME marks its frame at the vblank IRQ
        {
            bool irq = R.wrally_board__DOT__dbg_irq;
            if (irq && !irq_prev) {
                if (frame + 1 >= trace_from) tracing = true;
                if (trace && tracing) fprintf(trace, "# frame %d\n", frame + 1);
                if (mem_dumps.count(frame + 1)) mem_dump(frame + 1);
                fprintf(stats, "%d,%llu,%llu,%ld,%d,%d,%ld,%d,%d,%d,%d,%d\n", frame, (unsigned long long)(cyc - cyc0),
                        (unsigned long long)(bus_cycles - bus_cycles_f), mtraced - mcu_f,
                        (int)R.wrally_board__DOT__dbg_vcnt, owed_max, lost,
                        w_max[0], w_max[1], w_max[2], w_max[3], w_max[4]);
                owed_max = 0;
                lost_all += lost; lost = 0;
                for (int p = 0; p < NP; p++) { if (w_max[p] > wait_all[p]) wait_all[p] = w_max[p]; w_max[p] = 0; }
                bus_cycles_f = bus_cycles; mcu_f = mtraced;
                fflush(stats);
                if (frame % 10 == 0)
                    fprintf(stderr, "frame %d of %d  (%ld accesses traced)\n", frame, frames, traced);
                frame++;
                apply_inputs(frame - 1);
            }
            irq_prev = irq;
        }

        // ---- video capture
        if (t->ce_pix) {
            int hb = t->hblank, vb = t->vblank;
            if (!hb && !vb) {
                if (x < W && y < H) {
                    uint8_t* px = &img[(y * W + x) * 3];
                    px[0] = t->r;
                    px[1] = t->g;
                    px[2] = t->b;
                }
                x++;
            }
            if (hb && !prev_hb && !vb) { y++; x = 0; }
            if (vb && !prev_vb) {
#ifdef SDR_REAL
                rb_want = true;
#endif
                if (dumps.count(frame)) {
                    char fn[1024];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), frame);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n%d %d\n255\n", W, H);
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                }
                if (scene) { if (frame < 2) spr_max = spr_cut = 0, spr_cut_at = 512; frame++; }
                y = 0; x = 0;
            }
            prev_hb = hb; prev_vb = vb;
        }
    }

    if (trace) fclose(trace);
    if (mtrace) fclose(mtrace);
    if (ticks) fclose(ticks);
    if (audio) fclose(audio);
    if (wlog) fclose(wlog);
    fclose(stats);
    fprintf(stderr, "board ticks lost %ld, longest waits (clocks) program %d tilemap0 %d tilemap1 %d "
                    "sprites %d oki %d\n",
            lost_all, wait_all[0], wait_all[1], wait_all[2], wait_all[3], wait_all[4]);
    fprintf(stderr, "sprites: longest line %ld clocks, %ld lines cut", spr_max, spr_cut);
    if (spr_cut) fprintf(stderr, " (the lowest at sprite %ld)", spr_cut_at);
    fprintf(stderr, "\n");
#ifdef SDR_REAL
    fprintf(stderr, "SDRAM protocol violations: %u\n", sd->violations);
#endif
    if (audio) fprintf(stderr, "audio: %ld samples\n", audio_n);
    fprintf(stderr, "%d frames, %ld 68000 accesses and %ld DS5002 accesses traced, %llu clocks\n",
            frames, traced, mtraced, (unsigned long long)(cyc - cyc0));
    t->final();
    delete t;
    return 0;
}
