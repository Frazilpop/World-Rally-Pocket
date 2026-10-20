-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally (Pocket): when in the frame the game writes the video
-- memories – the question World Rally 2's tear answered too late (a vreg
-- written mid-picture, read live by the board, never seen by MAME, which
-- draws the whole picture at vblank).
--
--   tools/pocket/mame_oracle.sh tools/mame_wrally_wlog.lua wrally \
--       WLOG_OUT=build/mame/wlog/race.txt WLOG_FRAMES=3000 INPUTS=race
--
-- Every 68000 write to the VRAM (100000-103fff), the vregs (108000-108007),
-- the video IRQ clear (10800c), the palette (200000-203fff) and the sprite
-- RAM (440000-440fff) is timed in 12 MHz clocks from the last vblank start
-- (MAME's frame notifier, where IRQ 6 is raised). On the board that is the
-- end of line 231 of jlrh's 513 x 260 frame at 8 MHz: a line is 769.5
-- clocks, vblank 28 lines = 21,546 clocks; a write later than that lands
-- inside the next picture, at line (t - 21546) / 769.5.
--
-- WLOG_OUT, one line a frame and region with writes:
--     <frame> <region> <count> <first clk> <last clk> <in picture> <first line> <changed>
-- "in picture" counts writes at t >= 21546, "first line" is the picture line
-- the first of them lands on (- if none), "changed" those in the picture that
-- changed the word stored (MAME's: the VRAM decrypted) – a rewrite of the
-- same value cannot show. At the end, a summary per region (also printed):
-- frames with writes, frames with any in the picture, frames with a changing
-- one there, the latest write seen. WLOG_FULL=<file> also logs every write:
--     <frame> <clk> <addr:06x> <data:04x> <mask:04x> <old:04x> <new:04x>
-- old and new being the stored word before and after (the data on the bus
-- is the encrypted word for the VRAM).
--
-- Environment: WLOG_OUT, WLOG_FULL, WLOG_FRAMES (default 3000), INPUTS
-- (mame_wrally_inputs.lua).

local OUT    = os.getenv("WLOG_OUT") or "wrally_wlog.txt"
local FULL   = os.getenv("WLOG_FULL")
local FRAMES = tonumber(os.getenv("WLOG_FRAMES") or "3000")
local VBL    = 21546
local LINE   = 769.5

local wr = dofile((os.getenv("WR_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                  .. "/mame_wrally_inputs.lua")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local fmt   = string.format

local shares = mach.memory.shares
local REG = { { "vram", 0x100000, 0x103fff, shares[":videoram"] },
              { "vregs", 0x108000, 0x108007, shares[":vregs"] },
              { "irqclr", 0x10800c, 0x10800d, nil },
              { "palette", 0x200000, 0x203fff, shares[":palette"] },
              { "sprites", 0x440000, 0x440fff, shares[":spriteram"] } }

local fh = assert(io.open(OUT, "w"))
local full = FULL and assert(io.open(FULL, "w")) or nil
fh:write("# frame region count first_clk last_clk in_picture first_line changed\n")

local frame, t_vbl = 0, 0.0
local cur = {}          -- region -> {n, first, last, late, late_first}
local tot = {}          -- region -> {frames, late_frames, max, max_frame}

local function clk() return math.floor((mach.time:as_double() - t_vbl) * 12e6 + 0.5) end

-- A write tap runs before the write: the word it leaves is read at the next
-- tap or frame notifier, by when the write has happened.
local pending = nil
local function settle()
  local p = pending
  if not p then return end
  pending = nil
  local new = p.share and p.share:read_u16(p.off) or 0
  if p.late and new ~= p.old then p.c.chg = p.c.chg + 1 end
  if full then full:write(fmt("%d %d %06x %04x %04x %04x %04x\n", p.frame, p.t, p.addr, p.data,
                              p.mask, p.old, new)) end
end

_G.wr_wlog_taps = {}
for _, r in ipairs(REG) do
  local name = r[1]
  tot[name] = { frames = 0, late = 0, chg = 0, max = -1, max_frame = 0 }
  _G.wr_wlog_taps[#_G.wr_wlog_taps + 1] = space:install_write_tap(r[2], r[3], "wr_wlog_" .. name,
    function(offset, data, mask)
      settle()
      local t = clk()
      local c = cur[name]
      if not c then c = { n = 0, first = t, last = t, late = 0, chg = 0 }; cur[name] = c end
      c.n = c.n + 1; c.last = t
      if t >= VBL then
        if c.late == 0 then c.late_first = t end
        c.late = c.late + 1
      end
      local sh, off = r[4], (offset & ~1) - r[2]
      pending = { share = sh, off = off, old = sh and sh:read_u16(off) or 0, late = t >= VBL,
                  c = c, frame = frame, t = t, addr = offset, data = data & 0xffff,
                  mask = mask & 0xffff }
    end)
end

local function flush_frame()
  settle()
  for _, r in ipairs(REG) do
    local name, c = r[1], cur[r[1]]
    if c then
      local line = c.late > 0 and fmt("%d", math.floor((c.late_first - VBL) / LINE)) or "-"
      fh:write(fmt("%d %s %d %d %d %d %s %d\n", frame, name, c.n, c.first, c.last, c.late, line, c.chg))
      local s = tot[name]
      s.frames = s.frames + 1
      if c.late > 0 then s.late = s.late + 1 end
      if c.chg > 0 then s.chg = s.chg + 1 end
      if c.last > s.max then s.max = c.last; s.max_frame = frame end
    end
  end
  cur = {}
end

_G.wr_wlog_frame = emu.add_machine_frame_notifier(function()
  flush_frame()
  frame = frame + 1
  t_vbl = mach.time:as_double()
  wr.frame(frame)
  if frame > FRAMES then
    for _, t in ipairs(_G.wr_wlog_taps) do t:remove() end
    fh:write("# summary: region frames_with_writes frames_with_writes_in_picture frames_changing_in_picture latest_clk (frame)\n")
    for _, r in ipairs(REG) do
      local s = tot[r[1]]
      local line = fmt("# %s %d %d %d %d (%d)", r[1], s.frames, s.late, s.chg, s.max, s.max_frame)
      fh:write(line .. "\n"); print("wlog" .. line:sub(2))
    end
    fh:close()
    if full then full:close() end
    mach:exit()
  end
end)
