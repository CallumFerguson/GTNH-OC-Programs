local component = require("component")
local me = component.me_interface
local db = component.database
local sides = require("sides")

local componentDiscoverLib = require("lib.component-discover-lib")

local mainNetInterfaceTP = componentDiscoverLib.discoverProxy("29e71936-ee78-4084-a7a2-5f4a4dec56e9", "mainNetInterfaceTP", "transposer")
local tank1TP            = componentDiscoverLib.discoverProxy("91d8d999-6d28-4b07-8517-095cfa558669", "tank1TP", "transposer")
local tank2TP            = componentDiscoverLib.discoverProxy("f8007880-a506-4557-ab06-3e7523c9ddfb", "tank2TP", "transposer")
local outputDustChestTP  = componentDiscoverLib.discoverProxy("d69f7134-dfab-44c2-9bd8-a6462551bca0", "outputDustChestTP", "transposer")

-- Read the tank on TOP (UP side) of each transposer
local fa = tank1TP.getFluidInTank(sides.up)
local fb = tank2TP.getFluidInTank(sides.up)

local a = (fa and fa[1] and tonumber(fa[1].amount)) or 0
local b = (fb and fb[1] and tonumber(fb[1].amount)) or 0

-- We'll use up to two interface slots (1 and 2), each can keep up to 64 items.
local IFACE_SLOT1 = 1
local IFACE_SLOT2 = 2

-- Original logic: request |a-b|-1 items. Clamp to [0, 128].
local KEEP_COUNT = math.max(0, math.abs(a - b) - 1)
if KEEP_COUNT > 128 then KEEP_COUNT = 128 end

assert(db and me, "Need a Database Upgrade in the Adapter and the Adapter must touch an ME (Dual) Interface")

-- Chest is always on TOP of outputDustChestTP
local chestSide = sides.top
local chestStack = outputDustChestTP.getStackInSlot(chestSide, 1)
if not chestStack then
  print("Output dust chest (top) slot 1 is empty. Nothing to request.")
  return
end

-- Build the WANT descriptor from the detected stack
local WANT = { name = chestStack.name }
if chestStack.damage ~= nil then WANT.damage = chestStack.damage end

print(("Requesting from ME: %s%s  (target total=%d)")
  :format(WANT.name, WANT.damage and (":" .. tostring(WANT.damage)) or "", KEEP_COUNT))

-- Overwrite DB slots and store our filter (use two db slots to be extra safe)
db.clear(1); db.clear(2)
assert(me.store(WANT, db.address, 1, 1), "store() failed (db slot 1)")
assert(me.store(WANT, db.address, 2, 1), "store() failed (db slot 2)")

-- Split keep across two interface slots
local keep1 = math.min(64, KEEP_COUNT)
local keep2 = math.max(0, KEEP_COUNT - keep1)

-- Configure slot 1
if keep1 > 0 then
  assert(me.setInterfaceConfiguration(IFACE_SLOT1, db.address, 1, keep1), "setInterfaceConfiguration slot1 failed")
else
  me.setInterfaceConfiguration(IFACE_SLOT1) -- unset
end

-- Configure slot 2 (only if needed)
if keep2 > 0 then
  assert(me.setInterfaceConfiguration(IFACE_SLOT2, db.address, 2, keep2), "setInterfaceConfiguration slot2 failed")
else
  me.setInterfaceConfiguration(IFACE_SLOT2) -- unset
end

-- Give the interface a moment to populate
os.sleep(0.5)

-- Pull from ME Interface attached to mainNetInterfaceTP (assumes interface is on its BOTTOM)
local ifaceSide = sides.bottom
local totalMoved = 0

for slot = 1, 2 do
  local ifaceStack = mainNetInterfaceTP.getStackInSlot(ifaceSide, slot)
  if ifaceStack and ifaceStack.size and ifaceStack.size > 0 then
    local moved = mainNetInterfaceTP.transferItem(ifaceSide, sides.top, ifaceStack.size, slot) or 0
    totalMoved = totalMoved + moved
    print(("Moved %d item(s) from interface slot %d."):format(moved, slot))
  else
    print(("Interface slot %d empty."):format(slot))
  end
end

-- Optional: stop refilling after this run
me.setInterfaceConfiguration(IFACE_SLOT1)
me.setInterfaceConfiguration(IFACE_SLOT2)

print(("Done. Total moved: %d"):format(totalMoved))
