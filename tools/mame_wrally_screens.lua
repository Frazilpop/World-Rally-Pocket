-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally (Pocket): MAME's picture for every frame in a range, as PNGs,
-- with the oracle's DIPs and inputs (tools/mame_wrally_inputs.lua).
--   tools/pocket/mame_oracle.sh tools/mame_wrally_screens.lua wrally \
--       SCREENS_DIR=build/mame/screens/wrally FROM=200 TO=700 STEP=1 INPUTS=race
-- Frame N is the Nth frame notification from power-on, as in
-- mame_wrally_dump.lua; the picture is screen:snapshot() (368 x 232), not
-- pixels(), which lags a frame inside the notifier.
local DIR   = os.getenv("SCREENS_DIR") or "."
local FROM  = tonumber(os.getenv("FROM") or "1")
local TO    = tonumber(os.getenv("TO") or "600")
local STEP  = tonumber(os.getenv("STEP") or "1")
local wr    = dofile((os.getenv("WR_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                     .. "/mame_wrally_inputs.lua")
local scr = manager.machine.screens[":screen"]
os.execute('mkdir -p "' .. DIR .. '"')
local n = 0
_G.wr_screens_notifier = emu.add_machine_frame_notifier(function()
  n = n + 1
  wr.frame(n)
  if n >= FROM and n <= TO and ((n - FROM) % STEP) == 0 then
    scr:snapshot(string.format("%s/m%05d.png", DIR, n))
  end
  if n % 300 == 0 then print(n .. " of " .. TO) end
  if n >= TO then manager.machine:exit() end
end)
