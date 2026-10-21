#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket) — the picture drawn from a MAME dump the way wrally.cpp's
# screen_update and gaelco_wrally_sprites.cpp draw it, standard library only;
# after World Rally 2 Pocket's.
"""Draw a picture from tools/mame_wrally_dump.lua's files, or one of the
harness's race frames line by line.

    render_dump.py DUMPDIR SET.rom OUT.ppm [--board] [--pixel X,Y]
    render_dump.py --run SIMDIR N WLOG SET.rom OUT.ppm [--pixel X,Y]

DUMPDIR holds vram.bin, palette.bin, spriteram.bin and vregs.bin; SET.rom
is tools/pocket/build_rom.py's image (its gfx fetch lines are the tiles).
Without --board the result should be the dump's screen.png, pixel for
pixel: the renderer below is MAME's. MAME's mix_sprites stops a pixel short
of the right and bottom edges (its loops run to cliprect.right() and
bottom(), which are inclusive), so no sprite is ever seen on the last
column or line; --board mixes them there too, as the board does, and should
give tb_wrally --scene's frame. --pixel X,Y lists what is drawn at one
pixel, in order.

--run draws picture N of a tb_wrally run as the board does (--board), from
the run's own memory: SIMDIR's vram, palette, spriteram and vregs at IRQ
N - 1 (--mem-dump), and WLOG's (--wlog) writes of frame N - 1 – those in
vblank (the sprite list among them) first, then those inside the picture,
each shown from the line and pixel it landed on. It should give the run's
frame_N.ppm exactly. MAME, drawing the whole picture at vblank, shows a
write inside the picture a frame early above where it landed; drawing the
dump at IRQ N the MAME way (DUMPDIR mode, the --mem-dump files under
MAME's names) gives MAME's picture N, and the two together tell those
pixels from any the board gets wrong.
"""
import struct
import sys

W, H = 368, 232
X0, Y0 = 8, 16                 # MAME's visible area: x 8-375, y 16-247
GFX = 0x300000
HTOTAL, VVIS = 513, 232        # the board's frame: pixels a line, lines shown


def words(path):
    d = open(path, "rb").read()
    return list(struct.unpack("<%dH" % (len(d) // 2), d))


def pen(rom, code, x, y):
    """Pixel (x, y) of 16x16 tile `code`: byte 4h + p of its row's line."""
    o = GFX + 8 * ((code & 0x3fff) * 16 + y) + 4 * (x >> 3)
    b = 7 - (x & 7)
    return sum(((rom[o + p] >> b) & 1) << p for p in range(4))


def colour(pal, idx):
    v = pal[idx & 0x1fff]
    return tuple(17 * ((v >> s) & 15) for s in (4, 0, 8))     # xBRG 444


def render(d, rom, board=False, watch=None, writes=()):
    """writes: (linear position, kind, index, word) in order, kind 'v' (VRAM),
    'r' (vregs), 'p' (palette) or 's' (sprite RAM, vblank's only); position
    line * HTOTAL + pixel, -1 for vblank."""
    vram, pal, spr, vregs = list(d["vram"]), list(d["pal"]), list(d["spr"]), list(d["vregs"])
    for _, k, a, v in writes:
        if k == "s":
            spr[a] = v
    writes = [w for w in writes if w[1] != "s"]
    log = []
    tw = [w for w in writes if w[1] != "p"]
    pw = [w for w in writes if w[1] == "p"]
    ti = pi = 0

    def note(x, y, what):
        if watch == (x - X0, y - Y0):
            log.append(what)

    def tile(n, x, y):
        """(pen, colour, category, code) of layer n at screen pixel (x, y)."""
        sx, sy = (vregs[1] + 4, vregs[0]) if n == 0 else (vregs[3], vregs[2])
        row, col = (y + sy) & 0x1ff, (x + sx) & 0x3ff
        t = (row >> 4) * 64 + (col >> 4)
        a, b = vram[(n << 12) + 2 * t], vram[(n << 12) + 2 * t + 1]
        px, py = col & 15, row & 15
        if b & 0x40: px = 15 - px                # TILE_FLIPYX: bit 6 x, bit 7 y
        if b & 0x80: py = 15 - py
        return pen(rom, a, px, py), b & 0x1f, (b >> 5) & 1, a & 0x3fff

    # the sprites, into MAME's temp bitmap
    sb = {}
    for i in range(3, (0x1000 - 6) // 2, 4):
        w0, w2, w3 = spr[i], spr[i + 2], spr[i + 3]
        sx = w2 & 0x3ff
        sy = (240 - (w0 & 0xff)) & 0xff
        num = w3 & 0x3fff
        col = (w2 & 0x7c00) >> 10
        effect, col = (col >> 4) & 1, col & 15
        hi = 1 if num >= 0x3700 else 0
        xf, yf = (w0 >> 14) & 1, (w0 >> 15) & 1
        for py in range(16):
            ypos = (sy + py) & 0x1ff
            if not Y0 <= ypos < Y0 + H:
                continue
            gpy = 15 - py if yf else py
            for px in range(16):
                xpos = (((sx + px) & 0x3ff) - 0x0f) & 0x3ff
                if not X0 <= xpos < X0 + W:
                    continue
                p = pen(rom, num, 15 - px if xf else px, gpy)
                src = sb.get((xpos, ypos), 0)
                if not effect:
                    if p:
                        sb[xpos, ypos] = p | (col << 4) | (hi << 8)
                        note(xpos, ypos, f"sprite {(i - 3) // 4} code {num:04x} colour {col} pen {p} high {hi}")
                elif 8 <= p < 16:
                    sb[xpos, ypos] = (src | ((p - 8) << 12) | 0x200) if src \
                        else ((p - 8) << 12) | (hi << 8) | 0x200
                    note(xpos, ypos, f"shadow sprite {(i - 3) // 4} code {num:04x} level {p - 8} high {hi}"
                                     f" -> {sb[xpos, ypos]:04x}")

    def mix(bmp, x, y, prio):
        if board or (x < X0 + W - 1 and y < Y0 + H - 1):
            s = sb.get((x, y), 0)
            if s and ((s >> 8) & 1) == prio:
                if not (s >> 9) & 1:
                    bmp = (s & 0xff) + 0x200
                elif s & 0xff:
                    bmp = (s & 0xff) + 0x200 + ((s >> 12) << 10)
                else:
                    bmp = (bmp & 0x3ff) + ((s >> 12) << 10)
                note(x, y, f"sprites (priority {prio}) -> {bmp:04x}")
        return bmp

    img = bytearray()
    for y in range(Y0, Y0 + H):
        for x in range(X0, X0 + W):
            here = (y - Y0) * HTOTAL + (x - X0)
            while ti < len(tw) and tw[ti][0] <= here:
                _, k, a, v = tw[ti]
                if k == "v": vram[a] = v
                else: vregs[a] = v
                note(x, y, f"{'VRAM' if k == 'v' else 'vreg'} {a:04x} <- {v:04x} landed")
                ti += 1
            while pi < len(pw) and pw[pi][0] <= here:
                pal[pw[pi][2]] = pw[pi][3]
                note(x, y, f"palette {pw[pi][2]:04x} <- {pw[pi][3]:04x} landed")
                pi += 1
            p1, c1, k1, t1 = tile(1, x, y)
            p0, c0, k0, t0 = tile(0, x, y)
            bmp = c1 * 16 + p1                              # layer 1, opaque
            note(x, y, f"layer 1 tile {t1:04x} colour {c1} pen {p1} category {k1}")
            note(x, y, f"layer 0 tile {t0:04x} colour {c0} pen {p0} category {k0}")
            if not k0 and p0:                               # layer 0, category 0
                bmp = c0 * 16 + p0
            if k1 and p1:                                   # layer 1, category 1
                bmp = c1 * 16 + p1
            if k0 and 1 <= p0 <= 7:                         # layer 0, category 1, pens 1-7
                bmp = c0 * 16 + p0
            bmp = mix(bmp, x, y, 0)
            if k0 and p0 >= 8:                              # layer 0, category 1, pens 8-15
                bmp = c0 * 16 + p0
            bmp = mix(bmp, x, y, 1)
            note(x, y, f"palette {bmp:04x}")
            img += bytes(colour(pal, bmp))
    return img, log


def run_writes(wlog, frame):
    """WLOG's writes of `frame`, as render() takes them, and the number of
    sprite RAM writes inside the picture (never expected, and not drawn:
    the board draws each line from the sprite RAM as it stands)."""
    out, spr_in = [], 0
    for line in open(wlog):
        f = line.split()
        if int(f[0]) != frame:
            continue
        ln, px, addr, word = int(f[1]), int(f[2]), int(f[3], 16), int(f[6], 16)
        pos = ln * HTOTAL + px if ln < VVIS else -1
        if 0x100000 <= addr < 0x104000:
            out.append((pos, "v", (addr >> 1) & 0x1fff, word))
        elif 0x108000 <= addr < 0x108008:
            out.append((pos, "r", (addr >> 1) & 3, word))
        elif 0x200000 <= addr < 0x204000:
            out.append((pos, "p", (addr >> 1) & 0x1fff, word))
        elif 0x440000 <= addr < 0x441000:
            if pos >= 0:
                spr_in += 1
            else:
                out.append((pos, "s", (addr >> 1) & 0x7ff, word))
    # the vblank's first: they come before the picture in the log's order
    return sorted(out, key=lambda w: w[0]), spr_in


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    run = "--run" in argv
    if len(args) < (5 if run else 3):
        print(__doc__, file=sys.stderr)
        return 2
    watch = None
    for i, a in enumerate(argv):
        if a == "--pixel":
            watch = tuple(int(v) for v in argv[i + 1].split(","))
            args = [x for x in args if x != argv[i + 1]]
    writes = ()
    if run:
        sim, n, wlog, rom_path, out = args[:5]
        n = int(n)
        d = {k: words(f"{sim}/{name}_{n - 1:05d}.bin") for k, name in
             (("vram", "vram"), ("pal", "palette"), ("spr", "spriteram"), ("vregs", "vregs"))}
        writes, spr_in = run_writes(wlog, n - 1)
        if spr_in:
            print(f"{spr_in} sprite RAM writes inside the picture, not drawn here", file=sys.stderr)
    else:
        dd, rom_path, out = args[:3]
        d = {"vram": words(f"{dd}/vram.bin"), "pal": words(f"{dd}/palette.bin"),
             "spr": words(f"{dd}/spriteram.bin"), "vregs": words(f"{dd}/vregs.bin")}
    rom = open(rom_path, "rb").read()
    img, log = render(d, rom, run or "--board" in argv, watch, writes)
    with open(out, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (W, H) + img)
    for line in log:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
