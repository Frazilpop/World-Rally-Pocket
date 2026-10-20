#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally for the Analogue Pocket — the ROM image builder.
"""Build the Pocket's SDRAM image (<set>.rom) for World Rally from MAME zips.

    python3 -I tools/pocket/build_rom.py wrally ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py all    ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py wrally ~/Downloads build/roms --regions

THE CONTRACT is the SDRAM layout in LAYOUT below. One file per set,
0x500000 bytes (5 MB), every part at its fixed base, every gap zero. The
Pocket loads the file at bridge address 0 and the shell writes byte n to
SDRAM byte n; SDRAM word w is {byte[2w+1], byte[2w]}.

  maincpu  0x000000  0x100000  68000 program, MAME's region as it is: byte 0
                               is the high byte of the first word
  ds5002   0x100000  0x008000  the DS5002FP's SRAM image (its program, and
                               its MOVX data 0x10000-0x17fff), as MAME's
                               gaelco_ds5002fp:sram region
  oki      0x200000  0x100000  the M6295's 1 MB of ADPCM, MAME's region as it
                               is (0x00000-0x2ffff fixed, 0x30000-0x3ffff a
                               64 KB bank of the whole)
  gfx      0x300000  0x200000  MAME's 2 MB gfx region rewritten as 64-bit
                               fetch lines, below

FETCH LINES. MAME's gfx region (wrally_tilelayout16) holds 16,384 tiles of
16 x 16 at 4 bpp. Tile t, row r, half h (h = 0 the left 8 pixels, 1 the
right) has one byte per plane, MSB the leftmost pixel:

    plane 0 (pen bit 0)  gfx[t*64 + 32*h + 2*r]
    plane 1              gfx[t*64 + 32*h + 2*r + 1]
    plane 2              gfx[0x100000 + t*64 + 32*h + 2*r]
    plane 3 (pen bit 3)  gfx[0x100000 + t*64 + 32*h + 2*r + 1]

(the EPROMs: plane 0 is i13, 1 i11, 2 i09, 3 i07, at chip byte t*32 + 16*h
+ r). The image keeps one 8-byte line per tile row, line L = t*16 + r:

    SDRAM byte 0x300000 + 8*L + 4*h + p  =  plane p of half h

so one 64-bit read is a whole 16-pixel tile row (plane p of the left half
in bits [8p+7:8p], of the right half in bits [8p+39:8p+32]), for a tilemap's
16-pixel run and a sprite's row alike, and the graphics stay 2 MB.

The mask-ROM sets (wrallyb, wrallyat, wrallyata) load h12 + h8 and c1 where
the others have i13/i11/i09/i07 and c01 + c03; their regions are the same
bytes (MAME loads them with no driver init), so every set's gfx and oki
slots are byte-identical — verify_rom.py checks it.

FILES ARE FOUND BY CRC32, NOT BY NAME OR PATH. A merged wrally.zip keeps the
clones' own files under wrallya/ .. wrallyata/; a split set keeps them in
their own zips. Every zip in ZIPDIR is indexed (central directory only,
nothing decompressed until needed), the set's own zip and its parent's are
preferred, and a directory ZIPDIR/<set>/ of loose files is accepted too.
Size and CRC pick the file; zipfile re-checks the CRC as it decompresses,
and the SHA1 is checked against MAME's before anything is written.

--regions writes OUTDIR/<set>_<region>.bin for MAME's four regions
(maincpu, ds5002 = gaelco_ds5002fp:sram, oki, gfx) at MAME's sizes, for the
Verilator harness.

This reads ROMs named on the command line and writes only where told —
build/ by convention, which is gitignored. No ROM data is in this file.
"""

import argparse
import hashlib
import os
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# --------------------------------------------------------------------- layout
# (region, base, slot size). gfx's slot holds the fetch lines, not the region.
LAYOUT = [
    ("maincpu", 0x000000, 0x100000),
    ("ds5002",  0x100000, 0x008000),
    ("oki",     0x200000, 0x100000),
    ("gfx",     0x300000, 0x200000),
]
IMAGE_SIZE = 0x500000
GFX_SIZE = 0x200000           # MAME's region
HALF = 0x100000               # planes 2 and 3 are in the second half
TILES = 0x4000
LINE = 8                      # bytes per fetch line: 2 halves x 4 planes

# ------------------------------------------------------------------ ROM_START
# Transcribed from MAME's wrally.cpp, ROM_START( wrally ) .. ( wrallyata ),
# in source order within each region. The plds region is left out: it is not
# on the board's buses, and gaelco_ds5002fp:mcu:internal (MON, RPCTL, CRCR)
# is the DS5002FP's own state, not data the board loads.
#
#   ("L", name, crc, sha1, offset, length)   ROM_LOAD
#   ("B", name, crc, sha1, offset, length)   ROM_LOAD16_BYTE: byte k -> offset+2k
#
# Region: (size, ops). Every region here has flag 0, every byte of it is
# loaded, and the image starts each from zeros.


def L(n, c, h, o, s): return ("L", n, c, h, o, s)
def B(n, c, h, o, s): return ("B", n, c, h, o, s)


def _program(even, odd):
    return (0x100000, [B(*even, 0x000000, 0x080000), B(*odd, 0x000001, 0x080000)])


SRAM = (0x8000, [L("wrdallas.bin", 0x547d1768,
                   "c58d1edd072d796be0663fb265f4739ec006b688", 0x0000, 0x8000)])

GFX_EPROM = (GFX_SIZE, [
    B("worldr21.i13", 0xb7fddb12, "619a75daac8cbba7e85c97ca19733e2196d66d5c", 0x000000, 0x080000),
    B("worldr20.i11", 0x58b2809a, "8741ec544c54e2a2f5d17ac2f8400ee2ce382e83", 0x000001, 0x080000),
    B("worldr19.i09", 0x018b35bb, "ca789e23d18cc7d7e48b6858e6b61e03bf88b475", 0x100000, 0x080000),
    B("worldr18.i07", 0xb37c807e, "9e6155a2b5206c0d4dca669d24d9fe9830027651", 0x100001, 0x080000),
])
OKI_EPROM = (0x100000, [
    L("worldr14.c01", 0xe931c2ee, "ea1cf8ad52713e5136a370e289567eea9e6403d6", 0x000000, 0x080000),
    L("worldr15.c03", 0x11f0fe2c, "96c2a04874fa036576b7cfc5559bb0e33582ffd2", 0x080000, 0x080000),
])
# "Same data, different layout" / "Same data in a single ROM" (MAME)
GFX_MASK = (GFX_SIZE, [
    L("rally h-12.h12", 0x3353dc00, "db3b1686751dcaa231d66c08b5be81fcfe299ad9", 0x000000, 0x100000),
    L("rally h-8.h8",   0x58dcd024, "384ff296d3c7c8e0c4469231d1940de3cea89fc2", 0x100000, 0x100000),
])
OKI_MASK = (0x100000, [
    L("sound c-1.c1", 0x2d69c9b8, "328cb3c928dc6921c0c3f0277f59bca6c747c504", 0x000000, 0x100000),
])


def _set(parent, even, odd, mask=False):
    return {"parent": parent, "regions": {
        "maincpu": _program(even, odd), "ds5002": SRAM,
        "oki": OKI_MASK if mask else OKI_EPROM,
        "gfx": GFX_MASK if mask else GFX_EPROM}}


SETS = {
    # checksum DE0D, 08 Nov 1993: the parent, with the title's extra censorship
    "wrally": _set(None,
        ("invers_taula_c23_coche_8-11-93_e.bin", 0x593189bf, "27d33d30d6cefdb55d2ff977784b93f6e410f0f0"),
        ("invers_taula_c22_coche_8-11-93_o.bin", 0xaf91579b, "5593868104e65d5a3c30be9b66d5a6ebf7d4a89d")),
    # checksum E586, 25 Jun 1993, marked "Japan"
    "wrallya": _set("wrally",
        ("rally c23.c23", 0xfbd57c94, "05036f076e6d8e765c04515e9d822c6006c1a378"),
        ("rally c22.c22", 0xdb73e0af, "6c1a6ee3d5dda76c3491159087ab9f7d49fa7dad")),
    # checksum 8AA2, mask ROMs, the extra censorship
    "wrallyb": _set("wrally",
        ("rally_c23.c23", 0xddd6f833, "f12f82c412fa93f46020d50c2620974ae2fb502b"),
        ("rally_c22.c22", 0x59a0d35c, "7c6f376a53c1e6d793cbfb16861ee3298ee013a1"), mask=True),
    # checksum 3873, 06 Apr 1993: "Power Failure"
    "wrallyc": _set("wrally",
        ("c23.bin", 0x8b7d93c3, "ce4163eebc5d4a0c1266d650523b1ffc702d1b87"),
        ("c22.bin", 0x56da43b6, "02db8f969ed5e7f5e5356c45c0312faf5f000335")),
    # checksum 0E56, 06 Apr 1993: "Tension baja"
    "wrallyd": _set("wrally",
        ("worldr17.c23", 0x050f5629, "74fc2cd5114f3bc4b2429f1d8d7eeb1658f9f179"),
        ("worldr16.c22", 0x9e0d126c, "369360b7ec2c3497af3bf62b4eba24c3d9f94675")),
    # checksum 3D84, 02 Apr 1993: the oldest
    "wrallye": _set("wrally",
        ("c23_2-4_27c040.bin", 0x2ccac665, "5026d688a04858ed53d9306dd7ff4a9fd61b2332"),
        ("c22_2-4_27c040.bin", 0xb76ac11f, "2d625d312af7d53200527f3d92449326d8f95030")),
    # checksum C448, Automáticos Canarios licence
    "wrallyac": _set("wrally",
        ("17_27c4001.c23", 0xad823c0e, "a7ac5e2143fe56dc48a6a212b74f6699e3003607"),
        ("16_27c4001.c22", 0x13921708, "1746f66167dfc8be3047963564adc317782a4f69")),
    # checksum 2CC1, Atari licence, Americas; mask ROMs
    "wrallyat": _set("wrally",
        ("rally.c23", 0x366595ad, "e16341ed9eacf9b729c28184268150ea9b62f185"),
        ("rally.c22", 0x0ad4ec6f, "991557cf25fe960b1c586e990e6019befe5a11d0"), mask=True),
    # checksum 75A5, 16 Jun 1993, Atari licence; mask ROMs
    "wrallyata": _set("wrally",
        ("rally_c23.c23", 0x291b3995, "92f9a84e3d3de762d0127e56590b8fd0a6e6a0eb"),
        ("rally_c22.c22", 0x25f0ee88, "60af7d7b7fb67fba0ed22d192e3369ea6afaf58a"), mask=True),
}
REGION_ORDER = ["maincpu", "ds5002", "oki", "gfx"]
# MAME's tag for each region, for the region dump and verify_rom.py.
MAME_REGION = {"maincpu": ":maincpu", "ds5002": ":gaelco_ds5002fp:sram",
               "oki": ":oki", "gfx": ":gfx"}


# --------------------------------------------------------------- ROM finding
class RomIndex:
    """Every ROM file under ZIPDIR, keyed by (size, crc32).

    Zips: the central directory gives both without decompressing anything.
    Loose files: only under ZIPDIR/<set>/ for the sets asked about (and their
    parents), hashed on demand — a whole Downloads folder is not read.
    """

    def __init__(self, zipdir):
        self.zipdir = zipdir
        self.entries = {}        # (size, crc) -> [(stem, kind, path, member)]
        self._loose_done = set()
        for name in sorted(os.listdir(zipdir)):
            path = os.path.join(zipdir, name)
            if name.lower().endswith(".zip") and os.path.isfile(path):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                stem = os.path.splitext(name)[0]
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    self.entries.setdefault((info.file_size, info.CRC), []).append(
                        (stem, "zip", path, info.filename))
                zf.close()

    def _add_loose(self, setname):
        if setname in self._loose_done:
            return
        self._loose_done.add(setname)
        d = os.path.join(self.zipdir, setname)
        if not os.path.isdir(d):
            return
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    data = fh.read()
                self.entries.setdefault((len(data), zlib.crc32(data)), []).append(
                    (setname, "file", p, None))

    def find(self, size, crc, prefer):
        for s in prefer:
            self._add_loose(s)
        cands = self.entries.get((size, crc), [])
        if not cands:
            return None
        rank = {s: i for i, s in enumerate(prefer)}
        return sorted(cands, key=lambda c: (rank.get(c[0], len(prefer)), c[0]))[0]

    def read(self, size, crc, sha1, prefer, name):
        hit = self.find(size, crc, prefer)
        if hit is None:
            raise SystemExit(f"missing ROM {name} (size {size:#x}, crc {crc:08x}) "
                             f"in {self.zipdir}: looked in every zip, preferring "
                             f"{', '.join(p + '.zip' for p in prefer)}")
        _, kind, path, member = hit
        if kind == "zip":
            with zipfile.ZipFile(path) as zf:
                data = zf.read(member)      # zipfile checks the CRC as it reads
        else:
            with open(path, "rb") as fh:
                data = fh.read()
        where = f"{os.path.basename(path)}:{member}" if member else path
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{name}: {where} does not match its CRC")
        if hashlib.sha1(data).hexdigest() != sha1:
            raise SystemExit(f"{name}: {where} has MAME's CRC but not its SHA1")
        return data, where


# ------------------------------------------------------------- region build
def build_regions(setname, index, log=print):
    """MAME's regions for a set, as its ROM_START leaves them."""
    spec = SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    out = {}
    for rname in REGION_ORDER:
        size, ops = spec["regions"][rname]
        buf = bytearray(size)
        for kind, name, crc, sha1, off, length in ops:
            data, where = index.read(length, crc, sha1, prefer, name)
            if kind == "L":
                if off + length > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:off + length] = data
            elif kind == "B":
                if off + 2 * length - 1 > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:off + 2 * length - 1:2] = data
            else:
                raise AssertionError(kind)
            log(f"    {rname:<8} {off:#08x} {kind} {name:<36} {crc:08x} <- {where}")
        out[rname] = bytes(buf)
    return out


def _line_sources():
    """For byte k = 4h + p of a fetch line: (gfx offset of tile 0 row 0)."""
    return [(HALF if p >= 2 else 0) + 32 * h + (p & 1) for h in range(2) for p in range(4)]


def gfx_lines(gfx):
    """The 2 MB gfx region as 256K fetch lines of 8 bytes (2 MB)."""
    if len(gfx) != GFX_SIZE:
        raise SystemExit(f"gfx is {len(gfx):#x}, expected {GFX_SIZE:#x}")
    out = bytearray(GFX_SIZE)
    for k, src in enumerate(_line_sources()):
        # line L = 16t + r reads gfx[src + 64t + 2r]: for each t the 16 rows
        # are a stride-2 run of 16 bytes
        col = bytearray(TILES * 16)
        for t in range(TILES):
            base = src + 64 * t
            col[16 * t:16 * t + 16] = gfx[base:base + 32:2]
        out[k::LINE] = col
    return bytes(out)


def gfx_from_lines(lines):
    """The inverse: MAME's gfx region from the fetch lines (for verify_rom.py)."""
    gfx = bytearray(GFX_SIZE)
    for k, src in enumerate(_line_sources()):
        col = lines[k::LINE]
        for t in range(TILES):
            base = src + 64 * t
            gfx[base:base + 32:2] = col[16 * t:16 * t + 16]
    return bytes(gfx)


def build_image(regions):
    img = bytearray(IMAGE_SIZE)
    parts = dict(regions, gfx=gfx_lines(regions["gfx"]))
    for rname, base, slot in LAYOUT:
        data = parts[rname]
        if len(data) > slot:
            raise SystemExit(f"{rname} is {len(data):#x}, over its {slot:#x} slot")
        img[base:base + len(data)] = data
    return bytes(img)


# -------------------------------------------------------------------- main
def expand_sets(arg):
    if arg == "all":
        return list(SETS)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(SETS)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="directory holding the MAME zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    ap.add_argument("--regions", action="store_true",
                    help="write <set>_<region>.bin per MAME region instead of <set>.rom")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    index = RomIndex(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    log = (lambda *x: None) if a.quiet else print
    for s in expand_sets(a.set):
        print(f"{s}:")
        regions = build_regions(s, index, log)
        if a.regions:
            for rname in REGION_ORDER:
                p = os.path.join(a.outdir, f"{s}_{rname}.bin")
                with open(p, "wb") as f:
                    f.write(regions[rname])
                print(f"  {p}  {len(regions[rname]):#x}")
        else:
            img = build_image(regions)
            p = os.path.join(a.outdir, f"{s}.rom")
            with open(p, "wb") as f:
                f.write(img)
            print(f"  {p}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
