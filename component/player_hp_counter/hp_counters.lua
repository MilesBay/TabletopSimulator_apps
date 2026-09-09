--==============================================================
-- The Dungeon of Fellstone -- per-player HP counters
-- Global.lua
--
-- Every seated player gets a Counter placed on the table rim,
-- next to their name plate, tinted to their seat colour and
-- labelled with their Steam name.
--==============================================================

local START_HP   = 20    -- Starting health for every player
local RIM_INSET  = 1.5   -- How far in from the table's outer edge to sit
local HOVER      = 0.4   -- Height above the rim, stops the counter clipping
local MIN_GAP    = 2.5   -- Minimum spacing between two counters
local LABEL_SIZE = 180   -- Font size of the name label

-- Seats that get a counter. Grey (spectator) and Black (GM) are excluded
-- on purpose -- neither of them has HP in our rules.
local SUPPORTED_COLORS = {
    "White", "Brown", "Red", "Orange", "Yellow",
    "Green", "Teal", "Blue", "Purple", "Pink",
}

-- Tables whose rim is round rather than rectangular. For these we place
-- counters on a circle; for the rest we place them on a box edge.
-- Approximate for hexagon/octagon, but close enough at these margins.
local ROUND_TABLES = {
    Table_Circular = true,
    Table_Glass    = true,
    Table_Plastic  = true,
    Table_Hexagon  = true,
    Table_Octagon  = true,
}

-- Seat colour -> GUID of that player's counter.
local counterGUIDs = {}


--==============================================================
-- Persistence
--==============================================================

function onSave()
    return JSON.encode(counterGUIDs)
end

function onLoad(saved_state)
    if saved_state and saved_state ~= "" then
        counterGUIDs = JSON.decode(saved_state) or {}
    end

    addContextMenuItem("Reset all HP", resetAllHP, false, true)
    refreshAll()
end


--==============================================================
-- Events
--==============================================================

-- Fires when a player takes a seat, switches seat, or disconnects
-- (a disconnect reports "Grey").
function onPlayerChangeColor(player_color)
    refreshAll()
end

function onPlayerDisconnect(player)
    refreshAll()
end


--==============================================================
-- Core
--==============================================================

-- Give a counter to every seated colour, take it away from every empty one.
function refreshAll()
    local seated = {}
    for _, p in ipairs(Player.getPlayers()) do
        if p.seated then
            seated[p.color] = true
        end
    end

    for _, color in ipairs(SUPPORTED_COLORS) do
        if seated[color] then
            giveCounter(color)
        else
            removeCounter(color)
        end
    end
end

function giveCounter(color)
    local existing = getCounter(color)
    if existing then
        -- Already有 one; the player may have changed their Steam name though.
        refreshLabel(existing, color)
        return
    end

    local pos, yaw = rimSpot(color)
    if not pos then return end
    pos = nudgeApart(pos, color)

    spawnObject({
        type     = "Counter",
        position = pos,
        rotation = {0, yaw or 180, 0},   -- Face the player who owns it
        sound    = false,
        callback_function = function(obj)
            obj.setName(labelFor(color))
            obj.setColorTint(Color.fromString(color))
            obj.setLock(true)
            obj.Counter.setValue(START_HP)
            counterGUIDs[color] = obj.getGUID()
            attachLabel(obj, color)
        end
    })
end

function removeCounter(color)
    local obj = getCounter(color)
    if obj then obj.destruct() end
    counterGUIDs[color] = nil
end

-- Returns the counter for a colour, or nil. Clears the stored GUID if the
-- object is gone, so a stale save file cannot block a respawn.
function getCounter(color)
    local guid = counterGUIDs[color]
    if not guid then return nil end

    local obj = getObjectFromGUID(guid)
    if obj == nil or obj.isDestroyed() then
        counterGUIDs[color] = nil
        return nil
    end
    return obj
end


--==============================================================
-- Placement
--==============================================================

-- Returns {x, y, z} on the table rim nearest this player's seat, plus the
-- yaw the counter should face. Returns nil if we cannot work it out.
function rimSpot(color)
    local tbl  = Tables.getTableObject()
    local hand = Player[color].getHandTransform()
    if not tbl or not hand then return nil end

    local b = tbl.getBounds()

    -- Unit vector from the table centre out towards the seat.
    local dx = hand.position.x - b.center.x
    local dz = hand.position.z - b.center.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return nil end   -- Seat is dead centre; nothing sensible to do
    dx, dz = dx / len, dz / len

    local halfX, halfZ = b.size.x / 2, b.size.z / 2
    local reach   -- Distance from the centre out to the outer edge

    if ROUND_TABLES[Tables.getTable()] then
        -- Round rim: same distance in every direction.
        reach = math.min(halfX, halfZ)
    else
        -- Rectangular rim: find where the ray leaves the bounding box.
        -- Whichever axis the ray crosses first is the edge it hits.
        local tx = (dx ~= 0) and (halfX / math.abs(dx)) or math.huge
        local tz = (dz ~= 0) and (halfZ / math.abs(dz)) or math.huge
        reach = math.min(tx, tz)
    end

    reach = reach - RIM_INSET

    local pos = {
        b.center.x + dx * reach,
        b.center.y + b.size.y / 2 + HOVER,
        b.center.z + dz * reach,
    }
    return pos, hand.rotation.y
end

-- Two players sitting close together map to nearly the same rim point.
-- Slide the newcomer sideways along the rim until it clears the others.
function nudgeApart(pos, color)
    local tbl = Tables.getTableObject()
    if not tbl then return pos end

    local c = tbl.getBounds().center
    local dx, dz = pos[1] - c.x, pos[3] - c.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return pos end

    -- Tangent to the rim at this point -- the direction we slide along.
    local tanX, tanZ = -dz / len, dx / len

    for _ = 1, 8 do   -- Bail out after 8 tries rather than loop forever
        local clash = false
        for other, guid in pairs(counterGUIDs) do
            if other ~= color then
                local obj = getObjectFromGUID(guid)
                if obj and not obj.isDestroyed() then
                    local p = obj.getPosition()
                    local d = math.sqrt((pos[1] - p.x) ^ 2 + (pos[3] - p.z) ^ 2)
                    if d < MIN_GAP then
                        clash = true
                        break
                    end
                end
            end
        end

        if not clash then break end
        pos[1] = pos[1] + tanX * MIN_GAP
        pos[3] = pos[3] + tanZ * MIN_GAP
    end

    return pos
end


--==============================================================
-- Labelling
--==============================================================

function labelFor(color)
    local player = Player[color]
    return (player and player.steam_name) or color
end

-- A zero-size button renders as plain text with no background and cannot be
-- clicked, which makes it a cheap floating label. click_function still has to
-- name a real function or the object errors on load, hence noop.
function attachLabel(obj, color)
    obj.createButton({
        click_function = "noop",
        label          = labelFor(color),
        position       = {0, 0.15, -1.1},
        rotation       = {0, 180, 0},
        width          = 0,
        height         = 0,
        font_size      = LABEL_SIZE,
        font_color     = Color.fromString(color),
    })
end

function refreshLabel(obj, color)
    local buttons = obj.getButtons()
    if buttons and #buttons > 0 then
        obj.editButton({index = 0, label = labelFor(color)})
    else
        attachLabel(obj, color)
    end
    obj.setName(labelFor(color))
end

function noop() end


--==============================================================
-- Utility
--==============================================================

-- Wired to the right-click menu on empty table space.
function resetAllHP(player_color, menu_position)
    for _, color in ipairs(SUPPORTED_COLORS) do
        local obj = getCounter(color)
        if obj then obj.Counter.setValue(START_HP) end
    end
    broadcastToAll("All HP reset to " .. START_HP, {1, 1, 1})
end
