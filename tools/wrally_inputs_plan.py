#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket): tools/mame_wrally_inputs.lua's INPUTS schedule as
# the harness's --inputs plan, so the two run the same drive.
#
#   python3 -I tools/wrally_inputs_plan.py race <frames> > build/sim/race.txt
#
# One line a frame where something changes, "<frame> coin=1 start=0 ...":
# the Lua script sets frame n's inputs in MAME's notifier n, seen from frame
# n's vblank on; the harness applies line n at its own vblank IRQ n.
import sys

KEYS = ("coin", "start", "b1", "left", "right", "test")


def race(n):
    return {
        "coin": int(600 <= n < 610),                       # Coin 1
        "start": int(700 <= n < 710),                      # 1 Player Start
        "b1": int((800 <= n < 1400 and n % 60 < 10) or n >= 1400),   # P1 Button 1
        "left": int(n >= 1600 and n % 240 < 30),
        "right": int(n >= 1600 and 120 <= n % 240 < 150),
        "test": 0,                                         # Service 2
    }


def session(n):
    if n < 5000:
        return race(n)
    return dict({k: 0 for k in KEYS}, test=int(5000 <= n < 5010),
                b1=int(n >= 5300 and n % 120 < 10))


def main():
    modes = {"none": lambda n: {k: 0 for k in KEYS}, "race": race, "session": session}
    if len(sys.argv) != 3 or sys.argv[1] not in modes:
        sys.exit("usage: wrally_inputs_plan.py none|race|session <frames>")
    mode, frames = sys.argv[1], int(sys.argv[2])
    plan = modes[mode]
    prev = None
    print(f"# INPUTS={mode}, tools/mame_wrally_inputs.lua's schedule")
    for n in range(0, frames + 1):
        cur = plan(n)
        changed = {k: v for k, v in cur.items() if prev is None or prev[k] != v}
        if changed:
            print(n, " ".join(f"{k}={v}" for k, v in changed.items()))
        prev = cur


if __name__ == "__main__":
    main()
