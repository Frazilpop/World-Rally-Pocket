// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally (Pocket) — the OKI alone, replaying MAME's commands.
//
//   tb_oki <set.rom> <oki log> <out.s16> [--frames N] [--chan file]
//
// wrally_oki (jt6295 and the bank) clocked as on the board: one clock a
// 12 MHz tick, cen every twelfth, so 1 MHz. The log is
// tools/mame_wrally_oki.lua's, "<frame> <addr> <data> <clock>": each write
// to 70000d (the bank, held here as wrally_iolatch holds it) or 70000f (the
// OKI) is made at its clock. The samples come from the .rom image's oki slot
// (0x200000, 16 x 64 KB) with no wait. Writes jt6295's 14-bit sum, unscaled,
// at its 48 kHz strobe as signed 16-bit little-endian mono, from clock 0 to
// the end of frame N (default: the log's last frame), 200,000 clocks a frame
// – a long attract's bank switching checked against MAME's WAV in minutes,
// where the whole board takes hours.
//
// Built with OKI_CHAN=1 (sim/oki/build.sh), --chan writes each channel's
// ADPCM signal (jt6295_adpcm's snd0-snd3, before the attenuation) at each
// OKI sample, four signed 16-bit words – to set against a model of MAME's
// voices channel by channel.

#include "Vwrally_oki.h"
#include "verilated.h"
#ifdef OKI_CHAN
#include "Vwrally_oki___024root.h"
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

struct W { long frame; unsigned addr, data; unsigned long long t; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        fprintf(stderr, "usage: %s set.rom oki_log out.s16 [--frames N]\n", argv[0]);
        return 2;
    }
    long frames = 0;
    const char* chan_path = nullptr;
    for (int i = 4; i + 1 < argc; i++)
        if (!strcmp(argv[i], "--frames")) frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--chan")) chan_path = argv[++i];
#ifdef OKI_CHAN
    FILE* chan = chan_path ? fopen(chan_path, "wb") : nullptr;
    bool sr_prev = false;
#else
    if (chan_path) { fprintf(stderr, "--chan needs a build with OKI_CHAN=1\n"); return 2; }
#endif

    std::vector<unsigned char> oki(0x100000);
    FILE* f = fopen(argv[1], "rb");
    if (!f || fseek(f, 0x200000, SEEK_SET) || fread(oki.data(), 1, oki.size(), f) != oki.size()) {
        fprintf(stderr, "%s: no oki slot\n", argv[1]);
        return 1;
    }
    fclose(f);

    std::vector<W> log;
    f = fopen(argv[2], "r");
    if (!f) { perror(argv[2]); return 1; }
    W w;
    while (fscanf(f, "%ld %x %x %llu", &w.frame, &w.addr, &w.data, &w.t) == 4) log.push_back(w);
    fclose(f);
    if (!frames) frames = log.empty() ? 1 : log.back().frame + 1;
    const unsigned long long end = 200000ULL * frames;

    FILE* out = fopen(argv[3], "wb");
    if (!out) { perror(argv[3]); return 1; }

    Vwrally_oki* t = new Vwrally_oki;
    t->clk = 0; t->rst = 1; t->cen = 0; t->cs_oki = 0; t->rwn = 1; t->din = 0; t->okibank = 0;
    t->sample_data = 0; t->sample_ok = 1;
    auto clock = [&]() {
        t->sample_data = oki[t->sample_addr & 0xfffff];
        t->clk = 1; t->eval();
        t->sample_data = oki[t->sample_addr & 0xfffff];
        t->clk = 0; t->eval();
    };
    for (int i = 0; i < 48; i++) clock();
    t->rst = 0;

    size_t k = 0;
    long n = 0, writes = 0;
    int hold = 0;
    for (unsigned long long c = 0; c < end; c++) {
        // a write's strobe held for four clocks, as the board's is on board time
        while (!hold && k < log.size() && log[k].t <= c) {
            if (log[k].addr == 0x70000d) { t->okibank = log[k].data & 15; k++; writes++; continue; }
            t->din = log[k].data; t->cs_oki = 1; t->rwn = 0; hold = 4; k++; writes++;
        }
        t->cen = (c % 12) == 0;
        clock();
        if (hold && --hold == 0) { t->cs_oki = 0; t->rwn = 1; }
#ifdef OKI_CHAN
        {
            auto& R = *t->rootp;
            bool sr = R.wrally_oki__DOT__u_oki__DOT__cen_sr;
            if (chan && sr && !sr_prev) {
                int16_t v[4] = {
                    (int16_t)(R.wrally_oki__DOT__u_oki__DOT__u_adpcm__DOT__snd0 << 4) >> 4,
                    (int16_t)(R.wrally_oki__DOT__u_oki__DOT__u_adpcm__DOT__snd1 << 4) >> 4,
                    (int16_t)(R.wrally_oki__DOT__u_oki__DOT__u_adpcm__DOT__snd2 << 4) >> 4,
                    (int16_t)(R.wrally_oki__DOT__u_oki__DOT__u_adpcm__DOT__snd3 << 4) >> 4 };
                fwrite(v, 2, 4, chan);
            }
            sr_prev = sr;
        }
#endif
        if (t->sample_tick) {
            int16_t s = (int16_t)(t->sound << 2) >> 2;   // 14 bits, sign-extended
            fwrite(&s, 2, 1, out);
            n++;
        }
        if (c % (200000ULL * 1000) == 0)
            fprintf(stderr, "%llu of %ld frames\n", c / 200000, frames);
    }
    fclose(out);
#ifdef OKI_CHAN
    if (chan) fclose(chan);
#endif
    fprintf(stderr, "%ld writes replayed, %ld samples (%.3f s)\n", writes, n, n / 48000.0);
    delete t;
    return 0;
}
