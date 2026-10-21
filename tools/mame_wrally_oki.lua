-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally (Pocket): every 68000 write to the OKI's bank (70000d) and to
-- the OKI itself (70000f), with the frame it fell in, for the bank switching
-- and the command stream; with MAME's -wavwrite beside it, the sound too.
--
--   tools/pocket/mame_oracle.sh tools/mame_wrally_oki.lua wrally \
--       OKI_OUT=build/mame/wav/attract_oki.txt OKI_FRAMES=24000 INPUTS=none \
--       -- -wavwrite build/mame/wav/attract.wav
--
-- OKI_OUT, one line a write: "<frame> <addr> <data> <clock>", frame N from
-- MAME's frame notification N ("# frame N" in mame_wrally_bus_trace.lua),
-- the clock in 12 MHz ticks of machine time from power-on – what
-- sim/oki/tb_oki replays. Exits at notification OKI_FRAMES.
local OUT    = os.getenv("OKI_OUT") or "wrally_oki.txt"
local FRAMES = tonumber(os.getenv("OKI_FRAMES") or "3000")
local wr = dofile((os.getenv("WR_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                  .. "/mame_wrally_inputs.lua")
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local fmt   = string.format
local fh = assert(io.open(OUT, "w"))
local frame, n = 0, 0

-- byte writes on the 16-bit bus: 70000d / 70000f are the low byte of the
-- words at 70000c / 70000e
_G.wr_oki_tap = space:install_write_tap(0x70000c, 0x70000f, "wr_oki", function(offset, data, mask)
  if mask & 0xff ~= 0 then
    fh:write(fmt("%d %06x %02x %d\n", frame, offset + 1, data & 0xff,
                 math.floor(mach.time:as_double() * 12e6 + 0.5)))
    n = n + 1
  end
end)

_G.wr_oki_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  wr.frame(frame)
  if frame % 1000 == 0 then print(frame .. " of " .. FRAMES); fh:flush() end
  if frame >= FRAMES then
    _G.wr_oki_tap:remove()
    fh:close()
    print(fmt("oki: %d writes in %d frames -> %s", n, frame, OUT))
    mach:exit()
  end
end)
