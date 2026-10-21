#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket) — after World Rally 2 Pocket's match_audio.py,
# standard library only.
"""Compare the board's sound with MAME's.

    match_audio.py CORE.s16 MAME.wav [--from SECONDS] [--to SECONDS] [--lags N]
                   [--gain G]

CORE.s16 is signed 16-bit mono at jt6295's 48 kHz strobe:
sim/wrally/tb_wrally's --audio (the board's output, from release) or
sim/oki/tb_oki's (jt6295's sum, unscaled, from power-on). MAME.wav is
-wavwrite's, mono at its own output rate (48 kHz), the OKI routed at 1.0.
CORE is multiplied by G (default 1) before it is compared.

The OKI makes a sample every 132 us (1 MHz / 132); jt6295 holds its sum
between them and MAME resamples to its output rate, and MAME's WAV is not in
step with emulated time to the sample, so the two are not compared sample
for sample. Both are averaged over each OKI period and smoothed over four,
and each second is scored at the lag (within +-N OKI samples, default 200)
where they agree best: the correlation, both levels and their ratio. The
same sound at the same level reads a correlation near 1 and a ratio near 1.
At the end: the levels over every second that has sound on both, and the
seconds with a correlation under 0.95.
"""
import math
import struct
import sys
import wave

RATE = 1e6 / 132


def read_core(path):
    d = open(path, "rb").read()
    n = len(d) // 2
    return list(struct.unpack("<%dh" % n, d[:2 * n])), 48000


def read_mame(path):
    w = wave.open(path)
    assert w.getsampwidth() == 2, "16-bit WAV expected"
    ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
    v = struct.unpack("<%dh" % (n * ch), w.readframes(n))
    return list(v[0::ch]), rate


def decimate(x, rate, count):
    """x averaged over each OKI sample period."""
    out = []
    step = rate / RATE
    for k in range(count):
        a, b = int(round(k * step)), int(round((k + 1) * step))
        seg = x[a:b]
        out.append(sum(seg) / len(seg) if seg else 0.0)
    return out


def smooth(x, w=4):
    """Each window summed afresh: a running sum leaves rounding residue in
    silence after a loud passage, which then correlates at +-1."""
    return [sum(x[max(0, i - w + 1):i + 1]) / w for i in range(len(x))]


def best_lag(o, m, lo, hi, lags):
    best = (-2.0, 0, 0.0, 0.0)
    for lag in range(-lags, lags + 1):
        if lo + lag < 0 or hi + lag > len(m):
            continue
        sxy = sxx = syy = 0.0
        for k in range(lo, hi, 2):
            x, y = o[k], m[k + lag]
            sxy += x * y; sxx += x * x; syy += y * y
        if sxx == 0 or syy == 0:
            continue
        r = sxy / math.sqrt(sxx * syy)
        if r > best[0]:
            best = (r, lag, math.sqrt(2 * sxx / (hi - lo)), math.sqrt(2 * syy / (hi - lo)))
    return best


def main(argv):
    args, opts, i = [], {}, 1
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]; i += 2
        else:
            args.append(argv[i]); i += 1
    if len(args) < 2:
        print(__doc__)
        return 2
    core, orate = read_core(args[0])
    mame, mrate = read_mame(args[1])
    lags = int(opts.get("--lags", "200"))
    gain = float(opts.get("--gain", "1"))
    count = int(min(len(core) / orate, len(mame) / mrate) * RATE)
    t0 = float(opts.get("--from", "0"))
    t1 = min(float(opts.get("--to", str(count / RATE))), (count - lags) / RATE)
    print(f"core {len(core)} samples ({len(core) / orate:.3f} s), MAME {len(mame)} at {mrate} Hz"
          f" ({len(mame) / mrate:.3f} s), gain {gain:g}")
    o = smooth([gain * v for v in decimate(core, orate, count)])
    m = smooth(decimate(mame, mrate, count))
    sec = int(t0)
    so = sm = 0.0
    low, sounded, silent_one = [], 0, []
    while sec + 1 <= t1:
        lo, hi = int(sec * RATE), int((sec + 1) * RATE)
        r, lag, rms_o, rms_m = best_lag(o, m, lo, hi, lags)
        if r == -2.0:
            eo = any(o[lo:hi]); em = any(m[lo:hi])
            if eo or em:
                silent_one.append(sec)
                print(f"{sec:4d} s  silent on {'MAME' if eo else 'core'} only")
            else:
                print(f"{sec:4d} s  silent on both")
        else:
            sounded += 1
            so += rms_o * rms_o; sm += rms_m * rms_m
            if r < 0.95:
                low.append(sec)
            print(f"{sec:4d} s  corr {r:6.3f} lag {lag:+4d}  rms {rms_o:6.0f} / {rms_m:6.0f}"
                  f"  ratio {rms_o / rms_m if rms_m else float('inf'):6.3f}")
        sec += 1
    if sounded:
        print(f"{sounded} s with sound: rms {math.sqrt(so / sounded):.0f} / {math.sqrt(sm / sounded):.0f}"
              f", ratio {math.sqrt(so / sm):.4f}; corr < 0.95 in {len(low)} s {low[:20]}"
              f"; sound on one only in {len(silent_one)} s {silent_one[:20]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
