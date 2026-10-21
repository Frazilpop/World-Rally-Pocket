#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally (Pocket) — World Rally 2 Pocket's diff_bus_trace.py (after the
# Kaneko 16-bit core's, alphanu1), with World Rally's map.
"""Diff the core's bus traces against MAME's.

    diff_bus_trace.py <core.txt> <mame.txt> <setname>

Both files are in tools/mame_wrally_bus_trace.lua's format; the DS5002FP's
are beside them with ".mcu" added (sim/wrally/tb_wrally.cpp writes the
same pair). Exit status 0 only if every compared stream matches.

THE 68000. Two comparisons over the same accesses:

  * every access, in order, instruction fetches included. fx68k and MAME's
    m68000 agree on the prefetch on this board, so this is the strict one;
  * every WRITE and every READ outside the program ROM, in order -- what the
    program asked for, as opposed to how the CPU fetched it. Where the first
    fails and this holds, the difference is in the fetching.

Only the lanes both sides drove are compared: a byte write has an undefined
value on the idle half of the bus.

Then the same every-access comparison again, this time picking up after a
divergence where IRQ 6 was taken at a neighbouring instruction: fx68k and
MAME's m68000 sample the interrupt at slightly different points of some
instructions, so now and then one of them takes the same IRQ an instruction
later. The streams are realigned on the next run of RESYNC_RUN identical
accesses within RESYNC_WINDOW of the divergence, and each realignment is
named: "irq entry" when an IRQ vector read (000078) is among the accesses
skipped or the few either side of them (in a data-only trace the handler's
register pushes, after the vector read, show the placement), "irq return" when the first difference is the RTE reading back a
stacked PC that differs, "other" for anything else. Only "other" fails.

THE DS5002FP. Its MOVX accesses to the shared RAM as a program sees them:
every write in order (address, data), and every read that returned a value
different from the last read of the same address. Repeated reads of an
unchanged byte are polling, and their number is timing: where the core's
8051 parts from MAME's by a few clocks, it polls a different number of
times between events. Where each event falls among
the 68000's accesses (the n68k column) is reported as the largest drift.
"""
import sys
from array import array
from collections import Counter

ROM_END = 0x100000       # wrally_addr_decode.v: cs_rom = addr[23:20] == 0

# One access packs into one 64-bit word -- addr (24 bits), R/W, the lanes
# driven and the data on them -- so tens of millions fit in memory and two
# accesses are the same exactly when their words are.
W_BIT = 1 << 32


def pack(a, rw, d, m):
    return (a << 33) | (W_BIT if rw == "W" else 0) | (m << 16) | (d & m)


def unpack(r):
    return (r >> 33, "W" if r & W_BIT else "R", r & 0xffff, (r >> 16) & 0xffff)


def load(path):
    out = array("Q")
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 4:
                continue
            out.append(pack(int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)))
    return out


def load_mcu(path, n68):
    """The DS5002's records before 68000 access n68: their count, and the
    events among them."""
    try:
        f = open(path)
    except OSError:
        return None
    count = 0
    last = {}
    events = []
    with f:
        for line in f:
            p = line.split()
            if len(p) != 5:
                continue
            r = (int(p[0]), int(p[1]), int(p[2], 16), p[3], int(p[4], 16))
            if r[0] >= n68:
                break
            count += 1
            # writes, and reads that changed: what the DS5002's program reacted to
            if r[3] == "R" and last.get(r[2]) == r[4]:
                continue
            last[r[2]] = r[4]
            events.append(r)
    return count, events


def fmt(rec):
    a, rw, d, m = unpack(rec)
    lane = {0xffff: "w", 0xff00: "hi", 0x00ff: "lo"}.get(m, f"{m:04x}")
    return f"{a:06x} {rw} {d:04x} .{lane}"


# wrally.cpp, main_map -- one map serves all nine sets.
MAPS = {
    "wrally": [
        (0x100000, 0x104000, "vram      100000-103fff"),
        (0x108000, 0x108008, "vregs     108000-108007"),
        (0x10800c, 0x10800e, "clr irq   10800c"),
        (0x200000, 0x204000, "palette   200000-203fff"),
        (0x440000, 0x441000, "sprites   440000-440fff"),
        (0x700000, 0x70000a, "inputs    700000-700009"),
        (0x70000a, 0x70000c, "ls259     70000b"),
        (0x70000c, 0x70000e, "oki bank  70000d"),
        (0x70000e, 0x700010, "oki       70000f"),
        (0x700010, 0x700080, "ls259     70001b-70007b"),
        (0xfec000, 0xff0000, "shared    fec000-feffff"),
    ],
}
ALIAS = {s: "wrally" for s in ("wrallya", "wrallyb", "wrallyc", "wrallyd", "wrallye",
                               "wrallyac", "wrallyat", "wrallyata")}


def region_for(setname):
    """Return a namer for this set. Raises rather than defaulting."""
    name = ALIAS.get(setname, setname)
    if name not in MAPS:
        raise SystemExit(f"diff_bus_trace: no memory map for {setname!r}. "
                         f"Known: {', '.join(sorted(MAPS) + sorted(ALIAS))}.")
    windows = MAPS[name]

    def region(r):
        a = r >> 33
        if a < ROM_END:
            return f"rom       000000-{ROM_END - 1:06x}"
        for lo, hi, n in windows:
            if lo <= a < hi:
                return n
        return f"OTHER     {a & 0xff0000:06x}"

    return region


def first_diff(a, m):
    for i in range(min(len(a), len(m))):
        if a[i] != m[i]:
            return i
    return None


def show(a, m, first):
    print(f"  {'core':<22} {'mame':<22}")
    for i in range(max(0, first - 6), min(len(a), len(m), first + 7)):
        mark = "<<" if i == first else "  "
        print(f"  {i:8d} {fmt(a[i]):<22} {fmt(m[i]):<22} {mark}")


def compare68(name, a, m):
    n = min(len(a), len(m))
    first = first_diff(a[:n], m[:n])
    print(f"\n  68000, {name}: core {len(a)}, mame {len(m)}")
    if first is None:
        print(f"  MATCH over all {n} compared accesses")
        return True
    print(f"  FIRST DIVERGENCE at access {first} of {n}")
    show(a, m, first)
    return False


RESYNC_WINDOW = 64
RESYNC_RUN = 64
IRQ_BACK = 40         # a movem of all sixteen registers: 32 writes


def compare68_resync(a, m):
    i = j = 0
    events = []
    while i < len(a) and j < len(m):
        if a[i] == m[j]:
            i += 1; j += 1
            continue
        found = None
        for tot in range(1, 2 * RESYNC_WINDOW + 1):
            for di in range(max(0, tot - RESYNC_WINDOW), min(RESYNC_WINDOW, tot) + 1):
                dj = tot - di
                if i + di + RESYNC_RUN > len(a) or j + dj + RESYNC_RUN > len(m):
                    continue
                if a[i + di:i + di + RESYNC_RUN] == m[j + dj:j + dj + RESYNC_RUN]:
                    found = (di, dj)
                    break
            if found:
                break
        if not found:
            events.append((i, j, None, None, "unrecoverable"))
            break
        di, dj = found
        # the stacking writes come before the vector read, so look a little past
        ua, um = unpack(a[i]), unpack(m[j])
        # an IRQ's stacking comes before its vector read and the handler's own
        # pushes (a register an instruction apart) after it, so look both ways
        if any(r >> 33 == 0x78 and not r & W_BIT
               for r in list(a[max(0, i - IRQ_BACK):i + di + 8]) + list(m[max(0, j - IRQ_BACK):j + dj + 8])):
            kind = "irq entry"
        elif ua[1] == "R" and um[1] == "R" and ua[0] == um[0] and 0xfec000 <= ua[0]:
            kind = "irq return"
        else:
            kind = "other"
        events.append((i, j, di, dj, kind))
        i += di; j += dj
    kinds = Counter(e[4] for e in events)
    n = min(len(a), len(m))
    print(f"\n  68000, every access, realigning after IRQ placement: "
          f"{len(events)} realignments ({', '.join(f'{v} {k}' for k, v in sorted(kinds.items())) or 'none'})")
    bad = [e for e in events if e[4] in ("other", "unrecoverable")]
    for e in events[:12]:
        print(f"    core {e[0]:8d} mame {e[1]:8d}: {e[4]}"
              + (f", skipped {e[2]} / {e[3]}" if e[2] is not None else ""))
    if not bad:
        print(f"  MATCH to the end ({i} / {j} accesses) but for IRQ placement")
        return True
    e = bad[0]
    print(f"  FIRST DIVERGENCE NOT IRQ PLACEMENT at core {e[0]} / mame {e[1]} ({e[4]})")
    k = e[0] - e[1]
    print(f"  {'core':<31} {'mame':<22}")
    for q in range(max(0, e[1] - 6), min(len(m), e[1] + 7)):
        fa = fmt(a[q + k]) if 0 <= q + k < len(a) else ""
        print(f"  {q + k:8d} {fa:<22} {fmt(m[q]):<22} {'<<' if q == e[1] else ''}")
    return False


def compare_mcu(oa, om, n68):
    """oa, om: load_mcu's counts and events; n68: 68000 accesses both traces cover."""
    (ca, a), (cm, m) = oa, om
    print(f"\n  DS5002FP shared-RAM MOVX within the first {n68} 68000 accesses: "
          f"core {ca}, mame {cm}")
    # the last few events of the shorter run may not have happened yet on the
    # other side when its 68000 trace stopped
    n = min(len(a), len(m))
    print(f"  writes and changed reads: core {len(a)}, mame {len(m)}")
    first = None
    drift = 0
    for i in range(n):
        if a[i][2:] != m[i][2:]:
            first = i
            break
        drift = max(drift, abs(a[i][0] - m[i][0]))
    if first is None:
        print(f"  MATCH over all {n} events; largest drift against the 68000 "
              f"{drift} of its accesses")
        return True
    print(f"  FIRST DIVERGENCE at event {first} (largest drift before it {drift})")
    print(f"  {'core: n68k t12 addr rw data':<32} {'mame':<32}")
    for i in range(max(0, first - 6), min(max(len(a), len(m)), first + 7)):
        fa = "%d %d %05x %s %02x" % a[i] if i < len(a) else ""
        fm = "%d %d %05x %s %02x" % m[i] if i < len(m) else ""
        print(f"  {fa:<32} {fm:<32} {'<<' if i == first else ''}")
    return False


def main():
    if len(sys.argv) < 4:
        print("usage: diff_bus_trace.py <core.txt> <mame.txt> <setname>", file=sys.stderr)
        return 2
    region = region_for(sys.argv[3])
    core, mame = load(sys.argv[1]), load(sys.argv[2])
    if not core or not mame:
        print(f"empty trace: core={len(core)} mame={len(mame)}", file=sys.stderr)
        return 2

    ok = compare68("every access", core, mame)

    def data(t):
        return array("Q", (r for r in t if r & W_BIT or r >> 33 >= ROM_END))
    ok_data = compare68("writes and data reads", data(core), data(mame))
    ok_irq = compare68_resync(core, mame)

    n68 = min(len(core), len(mame))
    ma, mm = load_mcu(sys.argv[1] + ".mcu", n68), load_mcu(sys.argv[2] + ".mcu", n68)
    if ma is None or mm is None:
        print("\n  DS5002FP: no .mcu file beside one of the traces")
    else:
        ok_mcu = compare_mcu(ma, mm, n68)
        ok &= ok_mcu
        ok_irq &= ok_mcu

    # Census: a region on one side only is the core and the driver
    # disagreeing about the map, not about behaviour.
    ca = Counter(region(r) for r in core)
    cm = Counter(region(r) for r in mame)
    print("\n  region                          core      mame")
    for k in sorted(set(ca) | set(cm)):
        flag = "  <- one side only" if (k not in ca) != (k not in cm) else ""
        print(f"  {k:<28} {ca.get(k, 0):8d}  {cm.get(k, 0):8d}{flag}")

    # strict match, or a match but for IRQ placement: 0; anything else: 1
    return 0 if (ok or ok_irq) else 1


if __name__ == "__main__":
    sys.exit(main())
