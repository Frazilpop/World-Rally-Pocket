#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally for the Analogue Pocket — check the ROM images against MAME.
"""Check <set>.rom byte for byte against the regions MAME itself loads.

    python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket

For each set: runs MAME with tools/mame_wrally_regions.lua (dumps into
build/mame/regions/<set>/, skipped with --no-mame if they are already there),
then compares every slot of the .rom image with MAME's region:

  * maincpu, ds5002, oki — the slice [base, base + MAME's region size) must
    equal MAME's region exactly, and the rest of the slot must be zero.
  * gfx — the slot's fetch lines are turned back into a 2 MB region
    (build_rom.gfx_from_lines), which must equal MAME's gfx region; and,
    independently of that inverse, 1,024 tiles' pixels read from the fetch
    lines as build_rom.py documents them must equal the same tiles decoded
    from MAME's region by wrally_tilelayout16's own arithmetic.
  * every byte outside the four slots must be zero.

The mask-ROM sets (wrallyb, wrallyat, wrallyata) load their graphics and
samples from other chips than the EPROM sets; every set in the run must
have the gfx, oki and ds5002 slots of the first, byte for byte (the same
data on two kinds of chip, and the one DS5002FP image).

Exit status 0 only if every set matches.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (the module beside this file)

REPO = build_rom.REPO
LUA = os.path.join(REPO, "tools", "mame_wrally_regions.lua")


def run_mame(setname, zipdir, dumpdir, mame):
    os.makedirs(dumpdir, exist_ok=True)
    # a fresh cfg and nvram every run: MAME keeps the DS5002FP's SRAM as NVRAM
    os.makedirs(os.path.join(REPO, "build", "mame", "run"), exist_ok=True)
    work = tempfile.mkdtemp(prefix=f"verify-{setname}.", dir=os.path.join(REPO, "build", "mame", "run"))
    env = dict(os.environ, DUMP_DIR=dumpdir)
    cmd = [mame, "-rompath", zipdir, setname,
           "-autoboot_script", LUA, "-skip_gameinfo", "-autoboot_delay", "0",
           "-video", "none", "-sound", "none", "-nothrottle", "-seconds_to_run", "60",
           "-cfg_directory", os.path.join(work, "cfg"),
           "-nvram_directory", os.path.join(work, "nvram"),
           "-snapshot_directory", os.path.join(work, "snap")]
    try:
        r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    finally:
        shutil.rmtree(work)
    if not os.path.exists(os.path.join(dumpdir, "regions.txt")):
        sys.stdout.write(r.stdout + r.stderr)
        raise SystemExit(f"{setname}: MAME did not dump its regions")


def first_diff(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return None
    lo, hi = 0, n            # binary search on equal prefixes
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid
    return lo if a[lo] != b[lo] else hi - 1


def count_diff(a, b):
    try:
        import numpy as np
        return int(np.count_nonzero(np.frombuffer(a, np.uint8) != np.frombuffer(b, np.uint8)))
    except ImportError:
        return sum(x != y for x, y in zip(a, b))


def compare(lines, name, base, mine, mame, note=""):
    d = first_diff(mine, mame)
    if d is None and len(mine) == len(mame):
        lines.append(f"  {name:<8} @{base:#09x}  {len(mame):#09x} bytes  MATCH{note}")
        return True
    if d is None:
        lines.append(f"  {name:<8} @{base:#09x}  MISMATCH: {len(mine):#x} bytes here, "
                     f"MAME's region {len(mame):#x}")
        return False
    lines.append(f"  {name:<8} @{base:#09x}  MISMATCH{note}: "
                 f"{count_diff(mine, mame)} bytes differ, first at +{d:#x} "
                 f"(rom {mine[d]:02x}, mame {mame[d]:02x})")
    return False


# wrally_tilelayout16 (wrally.cpp), in bits: planes MSB first
_FRAC = build_rom.HALF * 8
_PLANEOFS = (_FRAC + 8, _FRAC + 0, 8, 0)
_XOFS = tuple(range(8)) + tuple(256 + i for i in range(8))
_YOFS = tuple(16 * i for i in range(16))
_CHARINC = 64 * 8


def mame_pixel(gfx, t, x, y):
    pen = 0
    for po in _PLANEOFS:
        o = po + _XOFS[x] + _YOFS[y] + t * _CHARINC
        pen = (pen << 1) | ((gfx[o >> 3] >> (7 - (o & 7))) & 1)
    return pen


def line_pixel(lines, t, x, y):
    line = lines[8 * (16 * t + y):8 * (16 * t + y) + 8]
    h, b = x >> 3, 7 - (x & 7)
    return sum(((line[4 * h + p] >> b) & 1) << p for p in range(4))


def check_pixels(lines, mame, n=1024):
    tiles = [(k * 2654435761) % build_rom.TILES for k in range(n)]   # spread over all
    bad = [(t, x, y) for t in tiles for y in range(16) for x in range(16)
           if mame_pixel(mame, t, x, y) != line_pixel(lines, t, x, y)]
    return len(tiles), bad


def verify(setname, romdir, dumpdir):
    img = open(os.path.join(romdir, f"{setname}.rom"), "rb").read()
    lines = []
    if len(img) != build_rom.IMAGE_SIZE:
        return False, [f"  image is {len(img):#x} bytes, expected {build_rom.IMAGE_SIZE:#x}"]
    ok = True
    covered = bytearray(len(img))
    for rname, base, slot in build_rom.LAYOUT:
        covered[base:base + slot] = b"\1" * slot
        mame = open(os.path.join(dumpdir, f"{rname}.bin"), "rb").read()
        if rname == "gfx":
            fetch = img[base:base + slot]
            ok &= compare(lines, rname, base, build_rom.gfx_from_lines(fetch), mame,
                          " (from the fetch lines)")
            nt, bad = check_pixels(fetch, mame)
            lines.append(f"  gfx      pixels of {nt} tiles from the lines == MAME's layout: "
                         + ("YES" if not bad else f"NO, {len(bad)} differ, first {bad[0]}"))
            ok &= not bad
            continue
        n = len(mame)
        ok &= compare(lines, rname, base, img[base:base + n], mame)
        if any(img[base + n:base + slot]):
            ok = False
            lines.append(f"  {rname:<8} slot tail after {n:#x} is not zero")
        elif slot > n:
            lines[-1] += f", slot tail {slot - n:#x} zero"
    stray = sum(1 for i in range(0, len(img), 0x8000)
                if not covered[i] and any(img[i:i + 0x8000]))
    if stray:
        ok = False
        lines.append(f"  {stray} 32K blocks outside the slots are not zero")
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--zipdir", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--mame", default="mame")
    ap.add_argument("--no-mame", action="store_true", help="reuse existing region dumps")
    a = ap.parse_args()

    sets = build_rom.expand_sets(a.set)
    all_ok = True
    for s in sets:
        d = os.path.join(a.dumpdir, s)
        if not a.no_mame:
            run_mame(s, os.path.expanduser(a.zipdir), d, a.mame)
        ok, lines = verify(s, a.romdir, d)
        print(f"{s}: {'OK' if ok else 'FAIL'}")
        print("\n".join(lines))
        all_ok &= ok
    if len(sets) > 1:
        imgs = {s: open(os.path.join(a.romdir, f"{s}.rom"), "rb").read() for s in sets}
        for rname, base, slot in build_rom.LAYOUT:
            if rname == "maincpu":
                continue
            ref = imgs[sets[0]][base:base + slot]
            odd = [s for s in sets[1:] if imgs[s][base:base + slot] != ref]
            print(f"{rname} slot the same in all {len(sets)} sets: "
                  + ("YES" if not odd else "NO, " + ", ".join(odd) + f" differ from {sets[0]}"))
            all_ok &= not odd
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
