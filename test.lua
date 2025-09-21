-- scale-tanks.lua
-- For OpenComputers in GT: New Horizons (MC 1.7.10)
-- Finds every transposer, and if there's a tank on TOP and BOTTOM:
--   Let top amount be t (mB). Target is t * MULTIPLIER (default 1000).
--   Moves (target - t) from BOTTOM -> TOP, clamped to TOP capacity.
-- Assumptions: bottom tank is "always full" and same fluid as top (we verify name).

print("starting...")

local component = require("component")
local sides     = require("sides")

-- If you want it to poll forever (e.g., every 2s), uncomment below:
-- while true do
--   runOnce()
--   os.sleep(2)
-- end

---------------------------------------------------------------------
-- quark.lua  (dust multiplier with two-pass read->move)
---------------------------------------------------------------------

local me = component.me_interface
local db = component.database
assert(me and db, "Need a Database Upgrade in the Adapter and the Adapter must touch an ME (Dual) Interface")

local componentDiscoverLib = require("lib.component-discover-lib")

-- Proxies
local mainNetInterfaceTP = componentDiscoverLib.discoverProxy(
  "69e81fc7-408f-4681-ade3-d0be031b4c94", "mainNetInterfaceTP", "transposer"
)
local outputDustChestTP = componentDiscoverLib.discoverProxy(
  "58b1c012-21f9-45cf-b35f-5382849e303f", "outputDustChestTP", "transposer"
)

-- Layout:
local SRC_SIDE   = sides.top     -- outputDustChest is on TOP of outputDustChestTP
local IF_SIDE    = sides.bottom  -- ME Interface is on BOTTOM of mainNetInterfaceTP
local DST_SIDE   = sides.top     -- destination chest is on TOP of mainNetInterfaceTP
local IFACE_SLOT = 1

---------------------------------------------------------------------
-- AE2 helpers
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- Main (Two-pass)
---------------------------------------------------------------------
local invSize    = outputDustChestTP.getInventorySize(SRC_SIDE) or 27
local grandTotal = 0

-- PASS 1: Read/record all dusts (stop at first empty slot)
print(("PASS 1: scanning output chest; invSize=%d"):format(invSize))
local tasks   = {}
local scanned = 0

for slot = 1, invSize do
  local st = outputDustChestTP.getStackInSlot(SRC_SIDE, slot)

  if not (st and st.size and st.size > 0) then
    print(("PASS 1: first empty at slot %d — stopping scan."):format(slot))
    break
  end

  scanned = scanned + 1
  local want = wantFromStack(st)
  if want then
    -- moving 8×; request up to one stack (64)
    local req = math.min(64, (st.size or 0) * 8)
    print(("PASS 1: slot %d -> %s%s x%d (req %d)")
      :format(
        slot,
        want.name,
        want.damage and (":" .. tostring(want.damage)) or "",
        st.size or 0,
        req
      ))

    if req > 0 then
      table.insert(tasks, {
        slot = slot,
        want = want,
        size = st.size or 0,
        req  = req
      })
    else
      print(("PASS 1: slot %d request is 0; skipping"):format(slot))
    end
  else
    print(("PASS 1: slot %d has no valid 'want' (missing name)"):format(slot))
  end
end

print(("PASS 1: scanned=%d, queued tasks=%d"):format(scanned, #tasks))