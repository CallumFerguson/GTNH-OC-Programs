-- run-on-redstone-io.lua (pull-based)
local event = require("event")
local sides = require("sides")
local componentDiscoverLib = require("lib.component-discover-lib")

-- CONFIG
local redstoneIO = componentDiscoverLib.discoverProxy("940e9d78-4fc4-49db-98cf-f0740d2dcada", "redstoneIO", "redstone")
local WATCH_SIDE = sides.top
local SCRIPT_PATH = "/home/getDust.lua"

assert(redstoneIO and redstoneIO.address, "Redstone I/O not found (check UUID / wiring).")

local function isRisingEdge(addr, side, oldValue, newValue)
  if addr ~= redstoneIO.address then return false end
  if side ~= WATCH_SIDE then return false end
  return oldValue == 0 and newValue > 0
end

print(("Armed on Redstone I/O %s, side=%s. (Ctrl+Alt+C to quit)")
  :format(string.sub(redstoneIO.address, 1, 8), sides[WATCH_SIDE]))

while true do
  local name, addr, side, oldValue, newValue, color =
    event.pullMultiple("redstone_changed", "interrupted")

  if name == "interrupted" then
    print("Interrupted; exiting.")
    break
  end

  -- Debug prints
--   print("EVENT:", name)
--   print("  addr:", addr)
--   print("  side:", side, "(watching", WATCH_SIDE, sides[WATCH_SIDE] .. ")")
--   print("  old:", oldValue, "new:", newValue, "color:", color)

  if isRisingEdge(addr, side, oldValue, newValue) then
    print("running script")
    dofile(SCRIPT_PATH)
  else
    -- print("  (ignored)")
  end
end
