-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally (Pocket): the DIPs and inputs every oracle script runs with,
-- loaded by tools/mame_wrally_{bus_trace,dump,screens,wlog}.lua with dofile.
--
-- DIPs: every one at MAME's default (DSW 0xFFDF: Normal, Number of Joysticks
-- 2, Joystick, Demo Sounds On, Upright, Service off, 1C/1C, Start 1C/
-- Continue 1C, Free Play off) – checked here, set by nothing. This is the
-- word the core's DSW holds.
--
-- INPUTS (environment):
--   none     (default) nothing pressed: power-on, then the attract
--   race     a coin at frame 600, start at 700, button 1 (accelerate) tapped
--            from 800 (the menus take it as select; the tap at 900 picks
--            the rally) and held from 1400, steering left and right from
--            1600
--   session  the race to frame 5000, then Service 2 ("go to test mode now")
--            at 5000, the test menu stepped with button 1 to 6000 – for the
--            DS5002FP NVRAM measurement
--
-- RALLY (environment, race and session): the rally the race picks –
-- sanremo (default: the tap at 900 takes the cursor where it starts), or
-- that tap and the one at 960 left out, right tapped from 910 every 24
-- frames, once for montecarlo, twice for acropolis, three times for lakes
-- (the cursor goes round clockwise; down does nothing there), and the tap
-- at 1020 picking.
--
-- Frame n is the nth machine frame notification from power-on (frame 1 is
-- the first picture MAME renders); an input set in notifier n is seen by the
-- program from frame n's vblank on. The Verilator harness applies the same
-- schedule at the same vblanks (tools/wrally_inputs_plan.py).
--
-- Returns a table: wr.frame(n) applies frame n's inputs (call it first in
-- the script's own frame notifier), wr.mode is the INPUTS value.

local mach  = manager.machine
local ports = mach.ioport.ports
local function field(port, name)
  local f = ports[port] and ports[port].fields[name]
  assert(f, "mame_wrally_inputs.lua: no field " .. port .. " " .. name)
  return f
end

local dsw = 0
for _, f in pairs(ports[":DSW"].fields) do dsw = dsw | (f.defvalue & f.mask) end
assert(dsw == 0xffdf, string.format("DSW defaults are %04x, not ffdf", dsw))

local mode = os.getenv("INPUTS") or "none"
assert(mode == "none" or mode == "race" or mode == "session",
       "INPUTS must be none, race or session, not " .. mode)

-- the cursor goes round clockwise, a step a tap of right
local RALLIES = { sanremo = 0, montecarlo = 1, acropolis = 2, lakes = 3 }
local rally_name = os.getenv("RALLY") or "sanremo"
local rally = RALLIES[rally_name]
assert(rally, "RALLY must be sanremo, montecarlo, lakes or acropolis, not " .. rally_name)

local P = {
  coin  = field(":P1_P2", "Coin 1"),
  start = field(":P1_P2", "1 Player Start"),
  b1    = field(":P1_P2", "P1 Button 1"),
  left  = field(":P1_P2", "P1 Left"),
  right = field(":P1_P2", "P1 Right"),
  test  = field(":SYSTEM", "Service 2"),
}

local wr = { mode = mode }

-- the schedule: name -> pressed at frame n (tools/wrally_inputs_plan.py
-- holds the same arithmetic)
local function race(n)
  local pick = n >= 910 and n < 910 + 24 * rally and (n - 910) % 24 < 6
  local skip = rally > 0 and ((n >= 900 and n < 910) or (n >= 960 and n < 970))
  return {
    coin  = n >= 600 and n < 610,
    start = n >= 700 and n < 710,
    b1    = ((n >= 800 and n < 1400 and (n % 60) < 10) or n >= 1400) and not skip,
    left  = n >= 1600 and (n % 240) < 30,
    right = (n >= 1600 and (n % 240) >= 120 and (n % 240) < 150) or pick,
    test  = false,
  }
end

local function session(n)
  if n < 5000 then return race(n) end
  return {
    coin = false, start = false, left = false, right = false,
    test = n >= 5000 and n < 5010,
    b1   = n >= 5300 and (n % 120) < 10,
  }
end

function wr.frame(n)
  if mode == "none" then return end
  local s = (mode == "race") and race(n) or session(n)
  for k, f in pairs(P) do f:set_value(s[k] and 1 or 0) end
end

print(string.format("wrally inputs: DSW %04x (MAME's defaults), INPUTS=%s RALLY=%s", dsw, mode, rally_name))
return wr
