#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket) — jt6295's voices against MAME's, standard library only.
"""Compare jt6295's four voices with MAME's, value for value.

    match_oki_channels.py JT.chan MODEL.chan

JT.chan is sim/oki/tb_oki --chan's (an OKI_CHAN=1 build), MODEL.chan
tools/pocket/oki_model.py --chan's, both four signed 16-bit words a sample:
each voice's ADPCM signal before the volume, 0 when idle. jt6295_adpcm's
snd0 holds the voice after voice 0 (its pipeline), so JT's are rotated back.

Timing is taken out: each voice's non-zero values are compared in order, as
sequences – the phrases' contents, their lengths, the bank they were read
from, the starts that were ignored. After a difference the two are put
back in step (up to 8 values skipped on either side, then 16 equal); each
difference is listed with the second it fell in and what was skipped.
"""
import struct
import sys


def read(path):
    d = open(path, "rb").read()
    v = struct.unpack("<%dh" % (len(d) // 2), d)
    return [v[c::4] for c in range(4)]


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    jt, mo = read(argv[1]), read(argv[2])
    jt = [jt[(c + 1) % 4] for c in range(4)]
    total = 0
    for c in range(4):
        A = [(i, x) for i, x in enumerate(jt[c]) if x]
        B = [(i, x) for i, x in enumerate(mo[c]) if x]
        i = j = eq = 0
        diffs = []
        while i < len(A) and j < len(B):
            if A[i][1] == B[j][1]:
                eq += 1; i += 1; j += 1
                continue
            best = None
            for di in range(9):
                for dj in range(9):
                    if (di or dj) and i + di + 16 <= len(A) and j + dj + 16 <= len(B) \
                            and all(A[i + di + k][1] == B[j + dj + k][1] for k in range(16)):
                        if best is None or di + dj < sum(best):
                            best = (di, dj)
            diffs.append((B[j][0] * 132e-6, best))
            if best is None:
                break
            i += best[0]; j += best[1]
        total += len(diffs)
        print(f"voice {c}: jt6295 {len(A)} values, MAME {len(B)}, {eq} equal, {len(diffs)} differences")
        for t, best in diffs[:20]:
            print(f"    {t:8.3f} s  " + ("out of step for good" if best is None else
                                         f"skipped {best[0]} of jt6295's, {best[1]} of MAME's"))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
