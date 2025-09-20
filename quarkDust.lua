-- quark.lua  (dust multiplier with early-exit on first empty slot)

local component = require("component")
local sides     = require("sides")

local me = component.me_interface
local db = component.database
assert(me and db, "Need a Database Upgrade in the Adapter and the Adapter must touch an ME (Dual) Interface")

local componentDiscoverLib = require("lib.component-discover-lib")

-- Proxies
local mainNetInterfaceTP = componentDiscoverLib.discoverProxy("69e81fc7-408f-4681-ade3-d0be031b4c94", "mainNetInterfaceTP", "transposer")
local outputDustChestTP  = componentDiscoverLib.discoverProxy("58b1c012-21f9-45cf-b35f-5382849e303f", "outputDustChestTP",  "transposer")

-- Layout:
local SRC_SIDE  = sides.top     -- outputDustChest is on TOP of outputDustChestTP
local IF_SIDE   = sides.bottom  -- ME Interface is on BOTTOM of mainNetInterfaceTP
local DST_SIDE  = sides.top     -- destination chest is on TOP of mainNetInterfaceTP
local IFACE_SLOT = 1

-- Helpers
local function wantFromStack(st)
  if not st or not st.name then return nil end
  local w = { name = st.name }
  if st.damage ~= nil then w.damage = st.damage end
  return w
end

local function ifaceRequest(want, count)
  db.clear(1)
  assert(me.store(want, db.address, 1, 1), "me.store failed")
  assert(me.setInterfaceConfiguration(IFACE_SLOT, db.address, 1, count), "setInterfaceConfiguration failed")
end

local function ifaceClear()
  me.setInterfaceConfiguration(IFACE_SLOT) -- unset
end

local function pullFromInterface(toMove)
  os.sleep(0.3) -- let interface populate
  local is = mainNetInterfaceTP.getStackInSlot(IF_SIDE, IFACE_SLOT)
  local avail = (is and is.size) or 0
  if avail <= 0 then return 0 end
  local n = math.min(avail, toMove)
  return mainNetInterfaceTP.transferItem(IF_SIDE, DST_SIDE, n, IFACE_SLOT) or 0
end

-- Main
local invSize = outputDustChestTP.getInventorySize(SRC_SIDE) or 27
local grandTotal = 0

for slot = 1, invSize do
  local st = outputDustChestTP.getStackInSlot(SRC_SIDE, slot)

  -- EARLY EXIT: first empty slot means everything after is empty too
  if not (st and st.size and st.size > 0) then
    break
  end

  local want = wantFromStack(st)
  if want then
    local req = math.min(64, (st.size or 0) * 8) -- < 1 stack requested total
    if req > 0 then
      print(("Slot %d: %s%s x%d -> requesting %d")
        :format(slot, want.name, want.damage and (":"..tostring(want.damage)) or "", st.size, req))

      ifaceRequest(want, req)
      local moved = pullFromInterface(req)
      ifaceClear()

      grandTotal = grandTotal + moved
      print(("  moved %d item(s) to destination chest"):format(moved))
    end
  end
end

ifaceClear()
print(("Done. Total moved: %d"):format(grandTotal))
