-- scale-tanks.lua
-- For OpenComputers in GT: New Horizons (MC 1.7.10)
-- Finds every transposer, and if there's a tank on TOP and BOTTOM:
--   Let top amount be t (mB). Target is t * MULTIPLIER (default 1000).
--   Moves (target - t) from BOTTOM -> TOP, clamped to TOP capacity.
-- Assumptions: bottom tank is "always full" and same fluid as top (we verify name).

print "starting..."

local component = require("component")
local sides     = require("sides")

---------------------------------------------------------------------
-- Tuning
---------------------------------------------------------------------
local MULTIPLIER = 1000   -- 1000x as requested
local VERBOSE    = true   -- set false for quieter logs

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function log(fmt, ...)
  if VERBOSE then
    print(string.format(fmt, ...))
  end
end

-- Safely fetch "the first" tank table on a side:
-- Returns table like {name=..., amount=..., capacity=...} or nil
local function firstTank(tp, side)
  local ok, tanks = pcall(tp.getFluidInTank, side)
  if not ok or type(tanks) ~= "table" then return nil end
  local t = tanks[1]
  if type(t) == "table" and (t.capacity or t.amount or t.name) then
    -- Normalize numeric fields
    t.amount   = tonumber(t.amount)   or 0
    t.capacity = tonumber(t.capacity) or 0
    return t
  end
  return nil
end

-- Quick check that a "tank" actually exists on a side.
-- Some drivers return { {capacity=0, amount=0} } for empty/nonexistent; we require capacity>0.
local function hasTank(tp, side)
  local t = firstTank(tp, side)
  return t and t.capacity and t.capacity > 0
end

-- Transfer fluid from one side to another, clamped to >=0
local function xfer(tp, fromSide, toSide, amount)
  if amount <= 0 then return 0 end
  local ok, moved = pcall(tp.transferFluid, fromSide, toSide, amount)
  if not ok then return 0 end
  return tonumber(moved) or 0
end

---------------------------------------------------------------------
-- Core logic for one transposer
---------------------------------------------------------------------
local function handleTransposer(addr)
  local tp = component.proxy(addr)
  if not tp then
    log("[%-8s] proxy failed.", string.sub(addr, 1, 8))
    return
  end

  local tag = string.format("[%s]", string.sub(addr, 1, 8))

  -- Need tanks on TOP and BOTTOM
  if not (hasTank(tp, sides.up) and hasTank(tp, sides.down)) then
    log("%s no valid tank on both TOP and BOTTOM; skipping.", tag)
    return
  end

  local top  = firstTank(tp, sides.up)
  local bot  = firstTank(tp, sides.down)
  local tAmt = top.amount or 0
  local tCap = top.capacity or 0

  -- If the top tank is totally empty (0 mB), multiplying by 1000 still yields 0; nothing to do.
  if tAmt <= 0 then
    log("%s top tank empty (0 mB). Nothing to scale.", tag)
    return
  end

  -- Ensure fluid types match (avoid mixing)
  -- If the top has a named fluid, require bottom to either be same name or bottom name missing (rare).
  if top.name and bot and bot.name and top.name ~= bot.name then
    log("%s fluid mismatch: top=%s, bottom=%s; skipping.", tag, tostring(top.name), tostring(bot.name))
    return
  end

  local target = MULTIPLIER * tAmt
  if tCap > 0 and target > tCap then
    target = tCap
  end

  local need = target - tAmt
  if need <= 0 then
    log("%s already at or above target (top=%d mB, target=%d mB).", tag, tAmt, target)
    return
  end

  local moved = xfer(tp, sides.down, sides.up, need)
  log("%s top=%d mB, target=%d mB, requested=%d mB",
      tag, tAmt, target, need)
end

---------------------------------------------------------------------
-- Discover and process all transposers
---------------------------------------------------------------------
local function runOnce()
  local count = 0
  for addr in component.list("transposer", true) do
    count = count + 1
    handleTransposer(addr)
  end
  if count == 0 then
    print("No transposers found.")
  end
end

-- Execute a single pass
runOnce()

-- If you want it to poll forever (e.g., every 2s), uncomment below:
-- while true do
--   runOnce()
--   os.sleep(2)
-- end

-- quark.lua  (dust multiplier with early-exit on first empty slot)

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
