#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket) — MAME's OKI M6295 in Python, standard library only.
"""MAME's okim6295 replayed from the game's writes.

    oki_model.py SET.rom OKI_LOG FRAMES OUT.s16 [--events FILE] [--chan FILE]

OKI_LOG is tools/mame_wrally_oki.lua's ("<frame> <addr> <data> <clock>",
every write to the bank at 70000d and the OKI at 70000f, the clock in
12 MHz ticks from power-on). The voices are MAME's (okim6295.cpp,
okiadpcm.cpp at mamedev/mame 9071ca1a): a write acts at once – a stop
silences its voices, a start on a voice not playing reads the phrase table
and plays 2 * (end - start + 1) nibbles from a reset ADPCM state, a start on
a voice playing is ignored – and each sample (1 MHz / 132, PIN7 high) adds
signal * volume / 2048 from every voice playing. The samples come from the
.rom image's oki slot (0x200000; 0x30000-0x3ffff from the bank, 16 x 64 KB,
as wrally.cpp's okibank).

OUT.s16 is the sum, scaled to 16 bits as MAME's WAV (x 32768) and held to
48 kHz as jt6295's strobe would sample it: for tools/pocket/match_audio.py.
--events writes the starts, stops, ignored starts, ends and bank changes with
the sample they fell on; --chan each voice's signal (before the volume, 0
when idle) at each sample, four signed 16-bit words, as sim/oki/tb_oki
--chan writes jt6295's: for tools/pocket/match_oki_channels.py.

Over the race (3,000 frames) against MAME's -wavwrite: correlation 0.95-0.998
a second, level 1.005 – the model is MAME's, sample for sample.
"""
import math
import struct
import sys

TICKS = 1584            # 12 MHz ticks a sample: 132 us
FRAME = 200000          # 12 MHz ticks a frame (MAME's 60 Hz)

INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]
VOLUME = [0x20, 0x16, 0x10, 0x0b, 0x08, 0x06, 0x04, 0x03, 0x02, 0, 0, 0, 0, 0, 0, 0]


def diff_lookup():
    out = []
    for step in range(49):
        sv = math.floor(16.0 * pow(11 / 10, step))
        for nib in range(16):
            s = -1 if nib & 8 else 1
            out.append(s * (sv * ((nib >> 2) & 1) + sv // 2 * ((nib >> 1) & 1)
                            + sv // 4 * (nib & 1) + sv // 8))
    return out


def main(argv):
    args, opts, i = [], {}, 1
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]; i += 2
        else:
            args.append(argv[i]); i += 1
    if len(args) < 4:
        print(__doc__)
        return 2
    with open(args[0], "rb") as f:
        f.seek(0x200000)
        rom = f.read(0x100000)
    log = []
    for line in open(args[1]):
        fr, a, d, t = line.split()
        log.append((int(a, 16), int(d, 16), int(t)))
    frames = int(args[2])
    ev = open(opts["--events"], "w") if "--events" in opts else None
    chan = open(opts["--chan"], "wb") if "--chan" in opts else None
    diff = diff_lookup()

    bank = 0

    def rd(a):
        a &= 0x3ffff
        return rom[a] if a < 0x30000 else rom[bank * 0x10000 + (a & 0xffff)]

    V = [dict(play=False, base=0, s=0, n=0, vol=0, sig=0, st=0) for _ in range(4)]
    cmd = -1
    n = frames * FRAME // TICKS
    out = []
    li = 0
    for k in range(n):
        t = k * TICKS
        while li < len(log) and log[li][2] <= t:
            a, d, _ = log[li]; li += 1
            if a == 0x70000d:
                bank = d & 15
                ev and ev.write(f"{k} bank {bank}\n")
            elif cmd != -1:
                for v in range(4):
                    if not (d >> (4 + v)) & 1:
                        continue
                    x = V[v]
                    if x["play"]:
                        ev and ev.write(f"{k} ignored start ch{v} phrase {cmd:02x}\n")
                        continue
                    b = cmd * 8
                    s0 = (rd(b) << 16 | rd(b + 1) << 8 | rd(b + 2)) & 0x3ffff
                    s1 = (rd(b + 3) << 16 | rd(b + 4) << 8 | rd(b + 5)) & 0x3ffff
                    if s0 < s1:
                        x.update(play=True, base=s0, s=0, n=2 * (s1 - s0 + 1), sig=0, st=0,
                                 vol=VOLUME[d & 15])
                        ev and ev.write(f"{k} start ch{v} phrase {cmd:02x} {s0:05x}-{s1:05x} att {d & 15}\n")
                    else:
                        ev and ev.write(f"{k} invalid start ch{v} phrase {cmd:02x}\n")
                cmd = -1
            elif d & 0x80:
                cmd = d & 0x7f
            else:
                for v in range(4):
                    if (d >> (3 + v)) & 1:
                        ev and ev.write(f"{k} stop ch{v}{'' if V[v]['play'] else ' (idle)'}\n")
                        V[v]["play"] = False
        acc = 0.0
        cv = [0, 0, 0, 0]
        for v, x in enumerate(V):
            if not x["play"]:
                continue
            nib = rd(x["base"] + x["s"] // 2) >> (((x["s"] & 1) << 2) ^ 4) & 15
            x["sig"] = max(-2048, min(2047, x["sig"] + diff[x["st"] * 16 + nib]))
            x["st"] = max(0, min(48, x["st"] + INDEX_SHIFT[nib & 7]))
            acc += x["sig"] * x["vol"] / 0x20 / 2048
            cv[v] = x["sig"]
            x["s"] += 1
            if x["s"] >= x["n"]:
                x["play"] = False
                ev and ev.write(f"{k} end ch{v}\n")
        if chan:
            chan.write(struct.pack("<4h", *cv))
        out.append(max(-32768, min(32767, int(acc * 32768))))
    n48 = n * TICKS // 250
    o48 = [out[min(n - 1, j * 250 // TICKS)] for j in range(n48)]
    with open(args[3], "wb") as f:
        f.write(struct.pack("<%dh" % len(o48), *o48))
    print(f"{n} OKI samples ({n * TICKS / 12e6:.3f} s), {li} writes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
