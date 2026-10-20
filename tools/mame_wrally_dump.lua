-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally (Pocket): dump the board's video state at chosen frames, with
-- MAME's own picture, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_wrally_dump.lua wrally \
--       DUMP_DIR=build/mame/dump/wrally DUMP_FRAME=600,2400 INPUTS=race
--
-- Environment:
--   DUMP_DIR    output directory. One frame: files go straight in it. Several
--               (DUMP_FRAME=600,1800,...): one subdirectory f<NNNNN> each.
--   DUMP_FRAME  frame number(s), counted as MAME frame notifications from
--               power-on: frame 1 is the first picture MAME renders.
--   DUMP_SET    optional; checked against the running set.
--   INPUTS      none (default) | race | session, mame_wrally_inputs.lua
--
-- Files (16-bit data as little-endian u16 words, as Mille Miglia's dumps):
--   vram.bin          100000-103fff, the video RAM as MAME stores it
--                     (decrypted): layer 0 at words 0-0xfff, layer 1 at
--                     0x1000-0x1fff, two words a tile, 8K words
--   vregs.bin         108000-108007: layer 0 y, x, layer 1 y, x
--   palette.bin       200000-203fff, 8K xBRG 444 words
--   spriteram.bin     440000-440fff, 2K words
--   shareram.bin      fec000-feffff, the 68000's words (the DS5002FP's MOVX
--                     bytes 0000-3fff, big-endian within each word)
--   ds5002_sram.bin   the DS5002FP's 32 KB SRAM, bytes
--   ds5002_iram.bin   its 128 bytes of internal RAM
--   screen.png        MAME's picture, 368 x 232 (screen:snapshot, -snapview
--                     native)
--   frame.json        frame numbers, time, the vregs, the OKI bank
--
-- FRAME ALIGNMENT. Everything is captured in the frame notifier, which MAME
-- calls at vblank_begin right after picture N was rendered and before either
-- CPU runs again. MAME draws the whole picture once, there, from the memory
-- as it stands (screen_update: no partial updates, no sprite buffer – the
-- sprites come from the live sprite RAM), so picture N is drawn from
-- exactly these dumps – to be confirmed by rendering them against
-- screen.png. The board draws line by line from the memory as it
-- stands at each line; where the game writes inside the picture the two
-- differ (tools/mame_wrally_wlog.lua says when it does).

local DIR = os.getenv("DUMP_DIR") or "."
local SET = os.getenv("DUMP_SET")
if DIR:sub(1, 1) ~= "/" then DIR = (os.getenv("PWD") or ".") .. "/" .. DIR end

local wr = dofile((os.getenv("WR_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                  .. "/mame_wrally_inputs.lua")

local FRAMES, WANT = {}, {}
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  FRAMES[#FRAMES + 1] = n; WANT[n] = true
end
table.sort(FRAMES)
local LAST = FRAMES[#FRAMES]

local mach    = manager.machine
local romname = emu.romname()
local KNOWN = { wrally = 1, wrallya = 1, wrallyb = 1, wrallyc = 1, wrallyd = 1, wrallye = 1,
                wrallyac = 1, wrallyat = 1, wrallyata = 1 }
assert(KNOWN[romname], "mame_wrally_dump.lua is for World Rally, not " .. romname)
assert(not SET or SET == romname, "DUMP_SET=" .. tostring(SET) .. " but running " .. romname)

local scr    = mach.screens[":screen"]
local shares = mach.memory.shares
local vram, vregs, pal, spr = shares[":videoram"], shares[":vregs"], shares[":palette"], shares[":spriteram"]
local shram, sram, iram = shares[":shareram"], shares[":gaelco_ds5002fp:sram"],
                          shares[":gaelco_ds5002fp:mcu:internal_ram"]
local okibank = mach.memory.banks[":okibank"]

-- ------------------------------------------------------------ writers
local outdir = DIR
local function words_le(get, n)
  local t, out = {}, {}
  for i = 0, n - 1 do
    local v = get(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t >= 4096 then out[#out + 1] = table.concat(t); t = {} end
  end
  out[#out + 1] = table.concat(t)
  return table.concat(out)
end
local function write(name, data)
  local f = assert(io.open(outdir .. "/" .. name, "wb"))
  f:write(data); f:close()
end
local function share16(sh) return words_le(function(i) return sh:read_u16(i * 2) end, sh.size // 2) end
local function bytes(sh)
  local t = {}
  for i = 0, sh.size - 1 do t[#t + 1] = string.char(sh:read_u8(i)) end
  return table.concat(t)
end

local function json_str(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c)
  return string.format("\\u%04x", c:byte()) end) .. '"' end

local frame = 0

local function dump_frame(n)
  outdir = (#FRAMES > 1) and string.format("%s/f%05d", DIR, n) or DIR
  os.execute('mkdir -p "' .. outdir .. '"')

  write("vram.bin", share16(vram))
  write("vregs.bin", share16(vregs))
  write("palette.bin", share16(pal))
  write("spriteram.bin", share16(spr))
  write("shareram.bin", share16(shram))
  write("ds5002_sram.bin", bytes(sram))
  if iram then write("ds5002_iram.bin", bytes(iram)) end
  local err = scr:snapshot(outdir .. "/screen.png")

  local f = assert(io.open(outdir .. "/frame.json", "w"))
  local function kv(k, v, last) f:write(string.format('  %s: %s%s\n', json_str(k), v, last and "" or ",")) end
  local function hex16(sh, off) return string.format('"%04x"', sh:read_u16(off)) end
  f:write("{\n")
  kv("set", json_str(romname))
  kv("inputs", json_str(wr.mode))
  kv("frame", n)
  kv("screen_frame_number", scr:frame_number())
  kv("machine_time", string.format("%.9f", mach.time:as_double()))
  kv("captured_in", json_str("frame notifier N = vblank_begin, right after picture N was rendered"))
  kv("scroll0y", hex16(vregs, 0)); kv("scroll0x", hex16(vregs, 2))
  kv("scroll1y", hex16(vregs, 4)); kv("scroll1x", hex16(vregs, 6))
  kv("okibank", okibank and okibank.entry or "null")
  kv("picture", json_str("screen.png = picture " .. n .. (err and (" (snapshot error " .. tostring(err) .. ")") or "")))
  kv("width", scr.width); kv("height", scr.height, true)
  f:write("}\n")
  f:close()
  print(string.format("dump: frame %d (screen frame %d) -> %s", n, scr:frame_number(), outdir))
end

_G.wr_dump_frame_sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  wr.frame(frame)
  if WANT[frame] then dump_frame(frame) end
  if frame >= LAST then mach:exit() end
end)
