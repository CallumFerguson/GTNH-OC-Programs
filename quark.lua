-- For OpenComputers in GT: New Horizons (MC 1.7.10)
-- Finds every transposer, and if there's a tank on TOP and BOTTOM:
--   Let top amount be t (mB). Target is t * MULTIPLIER (default 1000).
--   Moves (target - t) from BOTTOM -> TOP, clamped to TOP capacity.
-- Assumptions: bottom tank is "always full" and same fluid as top (we verify name).

print("starting...")

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
-- Some drivers return { {capacity=0, amount=0} } for empty/nonexistent; we require capacity > 0.
local function hasTank(tp, side)
  local t = firstTank(tp, side)
  return t and t.capacity and t.capacity > 0
end

-- Transfer fluid from one side to another, clamped to >= 0
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
  log("%s top=%d mB, target=%d mB, requested=%d mB", tag, tAmt, target, need)
  -- (Optional detail retained: 'moved' is computed but only 'requested' is logged, preserving original behavior.)
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
-- Curium fluid transposer (bottom -> top on PASS 1 when curium found)
local curiumFluidTP = componentDiscoverLib.discoverProxy(
  "7c6ec899-544e-4a13-bd20-7526efebed52", "curiumFluidTP", "transposer"
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

  -- Defaults
  local multiplier = 8
  local want = wantFromStack(st)
  local queueThis = true

  -- Special case: Iodine dust -> request BartWorks 11012 ×9, move iodine items north
  local isIodine = (st.name == "miscutils:itemDustIodine") and ((st.damage or 0) == 0)

  -- Special case: Curium dust -> move items north, move fluid on curiumFluidTP (bottom->top),
  -- skip PASS 2 (do not queue a task)
  local isCurium = (st.name == "miscutils:itemDustCurium") and ((st.damage or 0) == 0)

  if isCurium then
    -- Move curium items to NORTH
    local qty = st.size or 0
    local movedNorth = outputDustChestTP.transferItem(SRC_SIDE, sides.north, qty, slot) or 0
    print(("PASS 1: curium at slot %d -> moved %d to NORTH chest"):format(slot, movedNorth))

    -- Move fluid: 9 * 144 mB per curium
    local PER_DUST_MB = 9 * 144
    local fluidReq = (qty or 0) * PER_DUST_MB

    if curiumFluidTP and hasTank(curiumFluidTP, sides.down) and hasTank(curiumFluidTP, sides.up) then
      local top = firstTank(curiumFluidTP, sides.up) or { amount = 0, capacity = 0 }
      local capAvail = math.max(0, (top.capacity or 0) - (top.amount or 0))
      local toMove = math.min(fluidReq, capAvail)
      local moved = xfer(curiumFluidTP, sides.down, sides.up, toMove)
      print(("PASS 1: curium fluid move on [7c6ec899] requested=%d mB, moved=%d mB (capAvail=%d)")
        :format(toMove, moved, capAvail))
    else
      print("PASS 1: curium fluid transposer not ready (missing tanks) — skipped fluid move")
    end

    -- Do NOT queue a PASS 2 task for curium
    queueThis = false
  elseif isIodine then
    -- Override want + multiplier
    multiplier = 9
    want = { name = "bartworks:gt.bwMetaGenerateddust", damage = 11012 }

    -- Move iodine items to NORTH immediately
    local toMove = st.size or 0
    if toMove > 0 then
      local movedNorth = outputDustChestTP.transferItem(SRC_SIDE, sides.north, toMove, slot) or 0
      print(("PASS 1: iodine at slot %d -> moved %d to NORTH chest"):format(slot, movedNorth))
    else
      print(("PASS 1: iodine at slot %d but size=0; nothing moved to NORTH"):format(slot))
    end
  end

  if want and queueThis then
    local req = math.min(64, (st.size or 0) * multiplier)
    print(("PASS 1: slot %d -> %s%s x%d (req %d)%s%s")
      :format(
        slot,
        want.name,
        want.damage and (":" .. tostring(want.damage)) or "",
        st.size or 0,
        req,
        isIodine and " [SPECIAL iodine→bartworks ×9]" or "",
        isCurium and " [SPECIAL curium handled in PASS 1 only]" or ""
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
  elseif isCurium then
    print(("PASS 1: slot %d curium — no PASS 2 task queued"):format(slot))
  else
    print(("PASS 1: slot %d has no valid 'want' (missing name)"):format(slot))
  end
end

print(("PASS 1: scanned=%d, queued tasks=%d"):format(scanned, #tasks))

local UUID = "25c8462f-1235-4057-9577-cbd172331962"

-- Find the exact Redstone I/O by GUID (falls back to generic "redstone")
local rs = componentDiscoverLib.discoverProxy(UUID, "redstoneIO2", "redstone")
assert(rs and rs.address, "Redstone I/O not found (check UUID / wiring).")

-- 0.25 s pulse
rs.setOutput(sides.top, 15)
os.sleep(0.25)
rs.setOutput(sides.top, 0)

-- PASS 2: Perform the moves (note: curium slots were not queued)
for _, t in ipairs(tasks) do
  local want = t.want
  local req  = t.req

  print(("Slot %d: %s%s x%d -> requesting %d")
    :format(
      t.slot,
      want.name,
      want.damage and (":" .. tostring(want.damage)) or "",
      t.size,
      req
    ))

  ifaceRequest(want, req)
  local moved = pullFromInterface(req)
  ifaceClear()

  grandTotal = grandTotal + moved
  print(("  moved %d item(s) to destination chest"):format(moved))
end

ifaceClear()
print(("Done. Total moved: %d"):format(grandTotal))
