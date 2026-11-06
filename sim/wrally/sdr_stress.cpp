// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally (Pocket) — the shell's SDRAM path under a worst-case load.
//
//   sim/wrally/build_stress.sh [urgent]   (builds build/obj_stress_<urgent>_2/sdr_stress)
//   sdr_stress <frames> [seed]
//
// sdr_timing (kaneko_sdram_x2, kaneko_sdram, sdram_model, as core_top.v
// sets them up) driven by five requesters that behave as the board's do –
// a level request held until its ack, dropped on the next clock, at most
// one out – but asking far harder than the game ever does:
//
//   0 program   asks again 1-16 clocks after each line (the 68000 catching
//               up on owed board time), across its 1 MB
//   1, 2 tilemaps one line every 16 pixels (96 clocks) from hpos 481 of the
//               line before to the picture's right edge, on all 232 lines,
//               each layer at its own scroll, both changed every frame, so
//               the two layers' fetches meet at every spacing
//   3 sprites   asks again 1-4 clocks after each line for 95% of every line
//   4 OKI       one line every 50-2,000 clocks
//   5 read-back one line a frame (the overlay's check of line 0)
//
// All in bank 0, as the ROM image is, so nearly every change of port is a
// row miss; refresh as configured. Prints each port's longest wait in the
// harness's measure (clocks the request was held, the ack's clock counted;
// the overlay's counter reads one less) and how many tilemap fetches were
// held longer than 45 – the most a tile half survives at fixed latency
// (scene f01500: 0 late at 45, 178 at 46) – and longer than 40.

#include "Vsdr_timing.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

static const int NP = 6, AW = 25;
static const int CLK_PIX = 6, HTOTAL = 513, VTOTAL = 260, VIS = 232;

template <typename T>
static void setbits(T& w, int lo, int n, uint64_t v) {
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((v >> i) & 1) w[b >> 5] |= (1u << (b & 31));
        else              w[b >> 5] &= ~(1u << (b & 31));
    }
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s frames [seed]\n", argv[0]); return 2; }
    const int frames = atoi(argv[1]);
    std::mt19937 rng(argc > 2 ? atoi(argv[2]) : 1);
    auto rnd = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    Verilated::commandArgs(argc, argv);
    Vsdr_timing* sd = new Vsdr_timing;
    auto fast = [&]() { sd->clk_fast = 1; sd->eval(); sd->clk_fast = 0; sd->eval(); };
    sd->rst_n = 0; sd->s_req = 0;
    for (int i = 0; i < 8; i++) fast();
    sd->rst_n = 1;
    while (!sd->ready) fast();

    struct Port { bool req = false; int want = 0; uint32_t addr = 0; int held = 0; int gap = 0; };
    Port p[NP];
    long w_max[NP] = {0}, n_req[NP] = {0}, over45 = 0, over40 = 0, tm_n = 0;
    long hist[NP][128] = {{0}};
    uint32_t prog_pc = 0;

    for (int f = 0; f < frames; f++) {
        int sx[2] = { rnd(0, 15), rnd(0, 15) };     // each layer's scroll, mod 16 pixels
        int sub[2] = { rnd(0, CLK_PIX - 1), rnd(0, CLK_PIX - 1) };
        p[5].want++;
        for (int v = 0; v < VTOTAL; v++) {
            bool spr_on = true;
            int spr_end = HTOTAL * CLK_PIX * 95 / 100;
            for (int c = 0; c < HTOTAL * CLK_PIX; c++) {
                int h = c / CLK_PIX, ph = c % CLK_PIX;
                // tilemaps: the next line's lead (hpos 481-512 of line VIS-1.. -1) and the picture
                bool fetch_line = (v < VIS && h < 384) || ((v == VTOTAL - 1 || v < VIS - 1) && h >= 481);
                for (int l = 0; l < 2; l++)
                    if (fetch_line && ph == sub[l] && ((h + sx[l]) & 15) == 0) {
                        p[1 + l].want = 1;           // the romport asks for the latest address only
                        p[1 + l].addr = 0x180000 + (rnd(0, 0x3fff) << 6) + (rnd(0, 15) << 2);
                    }
                // program
                if (!p[0].req && p[0].want == 0 && --p[0].gap <= 0) {
                    p[0].want = 1;
                    prog_pc = rnd(0, 7) ? prog_pc + 4 : (uint32_t)rnd(0, 0x3ffff) << 2;
                    p[0].addr = prog_pc & 0x7fffc;
                }
                // sprites
                spr_on = c < spr_end;
                if (spr_on && !p[3].req && p[3].want == 0 && --p[3].gap <= 0) {
                    p[3].want = 1;
                    p[3].addr = 0x180000 + (rnd(0, 0x3fff) << 6) + (rnd(0, 15) << 2);
                }
                // OKI
                if (!p[4].req && p[4].want == 0 && --p[4].gap <= 0) {
                    p[4].want = 1;
                    p[4].addr = 0x100000 + ((uint32_t)rnd(0, 0x1ffff) << 2);
                }
                p[5].addr = 0;

                // one 48 MHz clock: the requests as they stand, two fast clocks
                uint32_t sreq = 0;
                for (int q = 0; q < NP; q++) {
                    if (p[q].req) sreq |= 1u << q;
                    setbits(sd->s_addr, q * AW, AW, p[q].addr);
                }
                sd->s_req = sreq;
                uint32_t ack = 0;
                for (int k = 0; k < 2; k++) { fast(); ack |= sd->s_ack; }
                // the edge: a held request counts the clock; acked, it drops
                for (int q = 0; q < NP; q++) {
                    Port& P = p[q];
                    if (P.req) {
                        P.held++;
                        if ((ack >> q) & 1) {
                            if (P.held > w_max[q]) w_max[q] = P.held;
                            hist[q][P.held < 127 ? P.held : 127]++;
                            n_req[q]++;
                            if (q == 1 || q == 2) {
                                tm_n++;
                                if (P.held > 45) over45++;
                                if (P.held > 40) over40++;
                            }
                            P.req = false; P.held = 0;
                            if (q == 0) P.gap = rnd(1, 16);
                            if (q == 3) P.gap = rnd(1, 4);
                            if (q == 4) P.gap = rnd(50, 2000);
                        }
                    } else if (P.want > 0) {
                        P.want--;
                        P.req = true; P.held = 0;
                    }
                }
            }
        }
    }
    printf("urgent %s, %d frames: longest waits program %ld tilemap0 %ld tilemap1 %ld sprites %ld oki %ld readback %ld\n",
           URGENT_STR, frames, w_max[0], w_max[1], w_max[2], w_max[3], w_max[4], w_max[5]);
    printf("lines served: program %ld tilemaps %ld sprites %ld oki %ld; tilemap fetches held over 40: %ld, over 45: %ld\n",
           n_req[0], tm_n, n_req[3], n_req[4], over40, over45);
    printf("violations %u\n", sd->violations);
    for (int q = 0; q < 5; q++) {
        printf("hist port %d:", q);
        for (int i = 0; i < 128; i++) if (hist[q][i]) printf(" %d:%ld", i, hist[q][i]);
        printf("\n");
    }
    delete sd;
    return 0;
}
