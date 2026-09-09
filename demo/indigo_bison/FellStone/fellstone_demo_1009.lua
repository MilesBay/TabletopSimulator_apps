--============================================================================
-- The Dungeon of Fellstone -- Global.lua
-- v1: built entirely from standard playing cards + text placeholders.
--
-- Paste into: Tabletop Simulator -> Scripting -> Global (Lua tab)
-- Companion panel goes in the XML tab -- see fellstone_ui.xml
--
-- Covers spec sections 0-5:
--   0  three standard 52-card decks supply everything
--   1  one layout formula + one MANIFEST
--   2  self-building dungeon on load
--   3  pieceBag / diceBag / classBag
--   4  per-seat player areas with owned hand zones
--   5  automatic seating
-- Combat slots (section 6) are positioned and wired, but the reveal is the
-- only combat logic present.
--============================================================================


--============================================================================
-- [1] CONFIG -- the only part you should normally edit
--============================================================================

local GRID_W, GRID_H = 7, 7

-- Cards are shrunk so the whole layout fits a default table. A poker card is
-- 2.3 x 3.2 TTS units at scale 1, so spacing is derived, never guessed.
local TILE_SCALE = 0.65
local GAP        = 0.35
local SPACING_X  = 2.3 * TILE_SCALE + GAP
local SPACING_Z  = 3.2 * TILE_SCALE + GAP

-- Centre of the grid. y sits slightly above the table surface.
local ORIGIN = { x = 0, y = 1.2, z = 0 }

local START_HP  = 4
local HAND_SIZE = 5

-- How far in from a player's hand zone their play area sits, and how far
-- the die / discard sit either side of it. Raise SEAT_INSET if a player area
-- overlaps the board on your table; lower it if it hangs off the edge.
local SEAT_INSET  = 5.0
local SEAT_SPREAD = 3.2

-- A locked health die cannot be knocked or re-rolled by accident, so the
-- number everyone reads stays true. HP is changed from its right-click menu.
-- Set false if you would rather players physically roll it.
local LOCK_HEALTH_DIE = true

local SEAT_COLORS = { "White", "Red", "Yellow", "Green", "Blue", "Purple" }

-- Six classes x (3 class cards + Dodge + Hidden Blade) = 30 combat cards.
-- These names are printed onto real playing cards, so the poker rank stays
-- visible underneath as a serial number during playtesting.
local CLASSES = {
    { name = "Priest",    cards = { "Priest - Heal",     "Priest - Smite",     "Priest - Sanctuary"  } },
    { name = "Archer",    cards = { "Archer - Longshot", "Archer - Volley",    "Archer - Retreat"    } },
    { name = "Warrior",   cards = { "Warrior - Cleave",  "Warrior - Guard",    "Warrior - Charge"    } },
    { name = "Mage",      cards = { "Mage - Fireball",   "Mage - Frost Nova",  "Mage - Blink"        } },
    { name = "Dark Mage", cards = { "Dark Mage - Drain", "Dark Mage - Curse",  "Dark Mage - Raise"   } },
    { name = "Paladin",   cards = { "Paladin - Judgement", "Paladin - Aegis",  "Paladin - Vow"       } },
}
local SHARED_CARDS = { "Dodge", "Hidden Blade" }

local FACE_DOWN = { x = 0, y = 180, z = 180 }
local FACE_UP   = { x = 0, y = 180, z = 0   }

local TAG_BUILD = "Fellstone"     -- everything this script spawns
local TAG_TILE  = "DungeonTile"   -- the 49 grid cards


--============================================================================
-- [2] MANIFEST -- one place to point at real components later
--
-- Leave a GUID as "" and the script spawns a placeholder for it. When you
-- have real art, paste the GUID here and nothing else changes.
--============================================================================

local MANIFEST = {
    dungeonDeck = "",   -- 104 cards: 49 to the grid, the rest is the draw pile
    pieceBag    = "",
    diceBag     = "",
    classBag    = "",
}


--============================================================================
-- [3] STATE
--============================================================================

local built        = {}   -- logical name -> GUID of the live object
local tiles        = {}   -- tiles[col][row] = card GUID
local cellOf       = {}   -- card GUID   -> { col, row }
local seats        = {}   -- colour      -> { spot, class, piece, die }
local usedSpots    = {}   -- spot index  -> colour
local usedClasses  = {}   -- class name  -> colour
local areas        = {}   -- colour      -> { play, die, discard, yaw }
local status       = "EMPTY"

local jobQueue     = {}
local workerBusy   = false


--============================================================================
-- [4] LAYOUT -- every position on the table derives from gridPos()
--============================================================================

-- col and row may be fractional or out of range; the maths is pure, so
-- "one column to the left of the board" is just gridPos(0, row).
-- Row 1 is the far side of the table, row GRID_H the near side.
local function gridPos(col, row)
    local ox = (GRID_W + 1) / 2
    local oz = (GRID_H + 1) / 2
    return {
        x = ORIGIN.x + (col - ox) * SPACING_X,
        y = ORIGIN.y,
        z = ORIGIN.z + (oz - row) * SPACING_Z,
    }
end

local MID_ROW  = (GRID_H + 1) / 2
local RIGHT_COL = GRID_W + 2.6
local Layout = {}

local function buildLayout()
    Layout.drawPile = gridPos(RIGHT_COL, MID_ROW)
    Layout.staging  = gridPos(RIGHT_COL, GRID_H)          -- scratch space for assembly
    Layout.bags = {
        pieceBag = gridPos(RIGHT_COL, 1),
        diceBag  = gridPos(RIGHT_COL, 2),
        classBag = gridPos(RIGHT_COL, 3),
    }
    Layout.combat = {
        gridPos(-1.9, MID_ROW - 0.7),
        gridPos(-1.9, MID_ROW + 0.7),
    }
    -- Six starting spots around the rim of the board, spread so that no two
    -- players begin adjacent to each other.
    Layout.startSpots = {
        gridPos(1.5, 0),
        gridPos(GRID_W - 0.5, 0),
        gridPos(GRID_W + 1, MID_ROW),
        gridPos(GRID_W - 0.5, GRID_H + 1),
        gridPos(1.5, GRID_H + 1),
        gridPos(0, MID_ROW),
    }
end


--============================================================================
-- [5] SMALL HELPERS
--============================================================================

-- Yield n frames. Only legal inside a coroutine.
local function pause(n)
    for _ = 1, (n or 1) do coroutine.yield(0) end
end

-- Look up a built or manifest object, clearing the reference if it is gone,
-- so a stale save file can never block a rebuild.
local function resolve(key)
    local guid = built[key] or MANIFEST[key]
    if guid == nil or guid == "" then return nil end
    local obj = getObjectFromGUID(guid)
    if obj == nil or obj.isDestroyed() then
        built[key] = nil
        return nil
    end
    return obj
end

-- Find an entry inside a bag by its display name.
local function findInBag(bag, name)
    if bag == nil then return nil end
    for _, entry in ipairs(bag.getObjects()) do
        if entry.nickname == name or entry.name == name then return entry end
    end
    return nil
end

local function claimSpot()
    for i = 1, #Layout.startSpots do
        if usedSpots[i] == nil then return i end
    end
    return nil
end

local function claimClass()
    local free = {}
    for _, class in ipairs(CLASSES) do
        if usedClasses[class.name] == nil then table.insert(free, class) end
    end
    if #free == 0 then return nil end
    return free[math.random(#free)]
end

local function setStatus(text)
    status = text
    pcall(function() UI.setValue("fellstoneStatus", text) end)
end

local function tint(color)
    local ok, c = pcall(Color.fromString, color)
    if ok then return c end
    return { 1, 1, 1 }
end


--============================================================================
-- [6] BUILD -- one coroutine, because every spawn needs frames to land
--============================================================================

local function spawnTagged(params, name)
    local obj = spawnObject(params)
    pause(3)
    if obj == nil then return nil end
    obj.addTag(TAG_BUILD)
    if name then obj.setName(name) end
    return obj
end

-- Destroy everything this script has ever spawned. Objects listed in
-- MANIFEST are yours, not ours, so they are never touched.
local function teardown()
    for _, obj in ipairs(getObjectsWithTag(TAG_BUILD)) do
        if not obj.isDestroyed() then obj.destruct() end
    end
    built, tiles, cellOf = {}, {}, {}
    seats, usedSpots, usedClasses = {}, {}, {}
    Global.setSnapPoints({})
end

local function makeBag(key, label)
    local bag = resolve(key)
    if bag then return bag end
    bag = spawnTagged({ type = "Bag", position = Layout.bags[key], sound = false }, label)
    if bag == nil then return nil end
    bag.setLock(true)
    built[key] = bag.getGUID()
    return bag
end

-- Two standard 52-card decks merged into one 104-card dungeon deck.
local function makeDungeonDeck()
    local deck = resolve("dungeonDeck")
    if deck then return deck end

    local a = spawnTagged({ type = "Deck", position = Layout.staging, sound = false })
    local b = spawnTagged({
        type = "Deck",
        position = { Layout.staging.x, Layout.staging.y + 4, Layout.staging.z },
        sound = false,
    })
    if a == nil or b == nil then return nil end

    local merged = a.putObject(b)
    pause(4)
    merged.addTag(TAG_BUILD)
    merged.setName("Dungeon Deck")
    built.dungeonDeck = merged.getGUID()
    return merged
end

local function dealDungeon(deck)
    deck.shuffle()
    pause(3)

    local need = GRID_W * GRID_H
    tiles, cellOf = {}, {}
    for col = 1, GRID_W do tiles[col] = {} end

    for i = 1, need do
        local col = ((i - 1) % GRID_W) + 1
        local row = math.floor((i - 1) / GRID_W) + 1
        local c, r = col, row   -- captured per iteration by the callback below

        deck.takeObject({
            position = gridPos(c, r),
            rotation = FACE_DOWN,
            smooth   = false,
            callback_function = function(card)
                card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
                card.addTag(TAG_TILE)
                card.addTag(TAG_BUILD)
                card.setDescription("Dungeon tile " .. c .. "," .. r)
                card.setLock(true)
                tiles[c][r]            = card.getGUID()
                cellOf[card.getGUID()] = { col = c, row = r }
            end,
        })
        -- One card per frame. Dealing all 49 in one frame is the single most
        -- common cause of cards landing in the wrong slot.
        pause(1)
    end

    pause(3)
    deck.setLock(true)
    deck.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
    deck.setPosition(Layout.drawPile)
    deck.setRotation(FACE_DOWN)
    deck.setName("Draw Pile")
end

-- Build the six 5-card class decks out of one standard deck, renaming each
-- card as it comes out. Cards are combined with putObject rather than
-- group(), because putObject returns the deck immediately and in order.
local function makeClassDecks(classBag)
    local source = spawnTagged({ type = "Deck", position = Layout.staging, sound = false },
                               "Combat Source")
    if source == nil then return end

    for _, class in ipairs(CLASSES) do
        local names = {
            class.cards[1], class.cards[2], class.cards[3],
            SHARED_CARDS[1], SHARED_CARDS[2],
        }

        local pile = nil
        for k, cardName in ipairs(names) do
            local card = source.takeObject({
                position = {
                    Layout.staging.x + 3,
                    Layout.staging.y + 0.6 * k,
                    Layout.staging.z,
                },
                rotation = FACE_DOWN,
                smooth   = false,
            })
            pause(3)
            card.setName(cardName)
            card.setDescription(class.name)
            card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
            card.addTag(TAG_BUILD)

            if pile == nil then
                pile = card
            else
                pile = pile.putObject(card)
            end
            pause(3)
        end

        pile.setName(class.name)
        pile.setDescription(class.name .. " starting hand")
        pile.addTag(TAG_BUILD)
        classBag.putObject(pile)
        pause(4)
    end

    -- 22 cards of the third deck are spare. Nothing needs them, so they go.
    if not source.isDestroyed() then source.destruct() end
end

local function fillPieceBag(bag)
    for _, color in ipairs(SEAT_COLORS) do
        local pawn = spawnTagged({
            type     = "PlayerPawn",
            position = { Layout.bags.pieceBag.x, Layout.bags.pieceBag.y + 3, Layout.bags.pieceBag.z },
            sound    = false,
        }, color .. " Adventurer")
        if pawn then
            pawn.setColorTint(tint(color))
            bag.putObject(pawn)
            pause(2)
        end
    end
end

local function fillDiceBag(bag)
    for _ = 1, #SEAT_COLORS do
        local die = spawnTagged({
            type     = "Die_6",
            position = { Layout.bags.diceBag.x, Layout.bags.diceBag.y + 3, Layout.bags.diceBag.z },
            sound    = false,
        }, "Health Die")
        if die then
            bag.putObject(die)
            pause(2)
        end
    end
end


--============================================================================
-- [7] PLAYER AREAS
--============================================================================

-- Where a seat's play area, die and discard sit. Derived from that colour's
-- hand zone, pulled in towards the middle of the table -- so it follows the
-- real seat, whatever table you switch to.
local function computeArea(color)
    if Player[color].getHandCount() == 0 then return nil end
    local hand = Player[color].getHandTransform()
    if hand == nil then return nil end

    local tbl = Tables.getTableObject()
    local c   = tbl and tbl.getBounds().center or { x = 0, y = 0, z = 0 }

    local dx, dz = hand.position.x - c.x, hand.position.z - c.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 0.01 then return nil end
    dx, dz = dx / len, dz / len

    local reach = len - SEAT_INSET
    local px, pz = c.x + dx * reach, c.z + dz * reach
    local tx, tz = -dz, dx   -- tangent: left/right along the table edge

    return {
        play    = { x = px,                    y = ORIGIN.y, z = pz                    },
        die     = { x = px + tx * SEAT_SPREAD, y = ORIGIN.y, z = pz + tz * SEAT_SPREAD },
        discard = { x = px - tx * SEAT_SPREAD, y = ORIGIN.y, z = pz - tz * SEAT_SPREAD },
        yaw     = hand.rotation.y,
    }
end

local function computeAllAreas()
    areas = {}
    local missing = {}
    for _, color in ipairs(SEAT_COLORS) do
        local a = computeArea(color)
        if a then
            areas[color] = a
        else
            table.insert(missing, color)
        end
    end
    if #missing > 0 then
        print("[Fellstone] No hand zone for: " .. table.concat(missing, ", ") ..
              ". Add one with the Hand tool, or use a table that has them.")
    end
end

-- Discard slot as a real scripting zone, so later code can read exactly what
-- is in it rather than guessing from a position.
local function spawnAreaMarkers(color, snaps)
    local a = areas[color]
    if a == nil then return end

    local zone = spawnTagged({
        type     = "ScriptingTrigger",
        position = { a.discard.x, a.discard.y, a.discard.z },
        rotation = { 0, a.yaw or 0, 0 },
        scale    = { 2.4, 2, 3.2 },
        sound    = false,
    }, color .. " Discard")
    if zone then built["discard_" .. color] = zone.getGUID() end

    local label = spawnTagged({
        type     = "3DText",
        position = { a.play.x, a.play.y + 0.05, a.play.z },
        rotation = { 90, a.yaw or 0, 0 },
        sound    = false,
    })
    if label then
        label.setValue(color)
        label.setColorTint(tint(color))
    end

    -- Snap points keep the die and discarded cards tidy without locking them.
    table.insert(snaps, { position = { a.die.x, a.die.y - 0.2, a.die.z } })
    table.insert(snaps, {
        position      = { a.discard.x, a.discard.y - 0.2, a.discard.z },
        rotation      = { 0, a.yaw or 0, 0 },
        rotation_snap = true,
    })
end

local function spawnCombatSlots(snaps)
    for i, pos in ipairs(Layout.combat) do
        local zone = spawnTagged({
            type     = "ScriptingTrigger",
            position = { pos.x, pos.y, pos.z },
            scale    = { 2.4, 2, 3.2 },
            sound    = false,
        }, "Combat Slot " .. i)
        if zone then built["combat_" .. i] = zone.getGUID() end
        table.insert(snaps, { position = { pos.x, pos.y - 0.2, pos.z }, rotation_snap = true })
    end
end


--============================================================================
-- [8] SEATING
--============================================================================

local function seatPlayer(color)
    if seats[color] then return end

    local spot  = claimSpot()
    local class = claimClass()
    if spot == nil or class == nil then
        broadcastToColor("No free starting spot or class is available.", color, { 1, 0.4, 0.4 })
        return
    end

    usedSpots[spot]         = color
    usedClasses[class.name] = color
    local record = { spot = spot, class = class.name }
    seats[color] = record

    local area = areas[color]

    -- 1. Piece, in that seat's colour, on a free starting spot.
    local pieceBag = resolve("pieceBag")
    local entry    = findInBag(pieceBag, color .. " Adventurer")
    if pieceBag and entry then
        local piece = pieceBag.takeObject({
            guid     = entry.guid,
            position = Layout.startSpots[spot],
            smooth   = false,
        })
        pause(3)
        if piece then record.piece = piece.getGUID() end
    end

    -- 2. Health die, showing 4.
    local diceBag = resolve("diceBag")
    if diceBag then
        local diePos = (area and area.die) or Layout.startSpots[spot]
        local die = diceBag.takeObject({ position = diePos, smooth = false })
        pause(4)
        if die then
            die.setName(color .. " HP")
            die.setColorTint(tint(color))
            die.setRotationValue(START_HP)
            pause(2)
            if LOCK_HEALTH_DIE then die.setLock(true) end
            die.addContextMenuItem("HP +1", function()
                die.setRotationValue(math.min(6, die.getRotationValue() + 1))
            end, true)
            die.addContextMenuItem("HP -1", function()
                die.setRotationValue(math.max(1, die.getRotationValue() - 1))
            end, true)
            record.die = die.getGUID()
        end
    end

    -- 3. A class nobody else has, dealt into this seat's hand zone.
    local classBag = resolve("classBag")
    local deckEntry = findInBag(classBag, class.name)
    if classBag and deckEntry then
        local deck = classBag.takeObject({
            guid     = deckEntry.guid,
            position = (area and area.play) or Layout.startSpots[spot],
            rotation = FACE_DOWN,
            smooth   = false,
        })
        pause(4)
        if deck then
            deck.deal(HAND_SIZE, color)
            pause(2)
        end
    end

    -- 4. Welcome.
    broadcastToColor(
        "You are the " .. class.name .. ". Health " .. START_HP .. ". " ..
        "On your turn: move up to three spaces, then flip the card you land on.",
        color, { 0.9, 0.9, 1 })
    broadcastToAll(color .. " has joined as the " .. class.name .. ".", tint(color))
end

local function unseatPlayer(color)
    local record = seats[color]
    if record == nil then return end

    local pieceBag = resolve("pieceBag")
    local diceBag  = resolve("diceBag")
    local classBag = resolve("classBag")

    -- Piece back to reserve.
    local piece = record.piece and getObjectFromGUID(record.piece)
    if piece and not piece.isDestroyed() then
        if pieceBag then pieceBag.putObject(piece) else piece.destruct() end
        pause(2)
    end

    -- Die back to reserve, stripped of its owner.
    local die = record.die and getObjectFromGUID(record.die)
    if die and not die.isDestroyed() then
        die.setLock(false)
        die.setName("Health Die")
        die.setColorTint({ 1, 1, 1 })
        if diceBag then diceBag.putObject(die) else die.destruct() end
        pause(2)
    end

    -- Hand back to reserve, reassembled into its class deck.
    local hand = Player[color].getHandObjects()
    if hand and #hand > 0 then
        local pile = nil
        for k, card in ipairs(hand) do
            card.setPosition({ Layout.staging.x + 3, Layout.staging.y + 0.6 * k, Layout.staging.z })
            pause(2)
            if pile == nil then pile = card else pile = pile.putObject(card) end
            pause(2)
        end
        pause(3)
        if pile and not pile.isDestroyed() then
            pile.setName(record.class)
            if classBag then classBag.putObject(pile) else pile.destruct() end
            pause(3)
        end
    end

    usedSpots[record.spot]    = nil
    usedClasses[record.class] = nil
    seats[color] = nil
    broadcastToAll(color .. " has left. The " .. record.class .. " is available again.", { 1, 1, 1 })
end


--============================================================================
-- [9] JOB QUEUE
--
-- Seating touches bags, and every take needs frames, so seating has to run
-- in a coroutine. startLuaCoroutine takes a named function with no arguments,
-- so jobs go through a queue and one worker drains it in order. Two players
-- sitting down in the same frame can therefore never race each other.
--============================================================================

local function enqueue(action, color)
    table.insert(jobQueue, { action = action, color = color })
    if not workerBusy then
        workerBusy = true
        startLuaCoroutine(Global, "fellstoneWorker")
    end
end

function fellstoneWorker()
    while #jobQueue > 0 do
        local job = table.remove(jobQueue, 1)
        if job.action == "seat" then
            seatPlayer(job.color)
        elseif job.action == "unseat" then
            unseatPlayer(job.color)
        elseif job.action == "build" then
            setStatus("Building...")
            teardown()
            pause(5)
            buildLayout()
            computeAllAreas()

            local snaps = {}
            local pieceBag = makeBag("pieceBag", "Piece Reserve")
            local diceBag  = makeBag("diceBag",  "Dice Reserve")
            local classBag = makeBag("classBag", "Class Reserve")

            local deck = makeDungeonDeck()
            if deck then dealDungeon(deck) end
            if classBag then makeClassDecks(classBag) end
            if pieceBag then fillPieceBag(pieceBag) end
            if diceBag  then fillDiceBag(diceBag)  end

            for _, color in ipairs(SEAT_COLORS) do spawnAreaMarkers(color, snaps) end
            spawnCombatSlots(snaps)
            Global.setSnapPoints(snaps)

            Hands.enable = true
            Hands.hiding = 1     -- each hand visible only to its owner

            setStatus("Ready")
            broadcastToAll("Fellstone table is ready. Take a seat.", { 0.4, 1, 0.4 })
            refreshSeats()
        end
        pause(2)
    end
    workerBusy = false
    return 1
end


--============================================================================
-- [10] EVENTS
--============================================================================

function refreshSeats()
    if status ~= "Ready" then return end

    local seated = {}
    for _, p in ipairs(Player.getPlayers()) do
        if p.seated then seated[p.color] = true end
    end

    for _, color in ipairs(SEAT_COLORS) do
        if seated[color] and seats[color] == nil then
            enqueue("seat", color)
        elseif not seated[color] and seats[color] ~= nil then
            enqueue("unseat", color)
        end
    end
end

function onPlayerChangeColor(player_color)
    refreshSeats()
end

function onPlayerConnect(player)
    refreshSeats()
end

function onPlayerDisconnect(player)
    refreshSeats()
end


--============================================================================
-- [11] UI HOOKS
--
-- An XML UI button is called as (player, value, id); an object button is
-- called as (obj, player_color, alt_click). None of these care, but keep it
-- in mind the first time you want to pass something in.
--============================================================================

function buildTable(player, value, id)
    if workerBusy then
        broadcastToAll("Already building.", { 1, 0.8, 0.3 })
        return
    end
    enqueue("build")
end

function clearTable(player, value, id)
    teardown()
    setStatus("Empty")
    broadcastToAll("Table cleared.", { 1, 0.8, 0.3 })
end

-- Beyond the v1 spec, but the slots exist, so the button may as well work.
function revealCombat(player, value, id)
    local flipped = 0
    for i = 1, 2 do
        local zone = built["combat_" .. i] and getObjectFromGUID(built["combat_" .. i])
        if zone and not zone.isDestroyed() then
            for _, obj in ipairs(zone.getObjects()) do
                if obj.type == "Card" then
                    obj.flip()
                    flipped = flipped + 1
                end
            end
        end
    end
    if flipped == 0 then
        broadcastToAll("Nothing in the combat slots.", { 1, 0.8, 0.3 })
    end
end


--============================================================================
-- [12] LOAD / SAVE
--============================================================================

function onSave()
    return JSON.encode({
        built       = built,
        tiles       = tiles,
        cellOf      = cellOf,
        seats       = seats,
        usedSpots   = usedSpots,
        usedClasses = usedClasses,
        status      = status,
    })
end

function onLoad(saved_state)
    math.randomseed(os.time())
    buildLayout()

    if saved_state ~= nil and saved_state ~= "" then
        local ok, s = pcall(JSON.decode, saved_state)
        if ok and type(s) == "table" then
            built       = s.built       or {}
            tiles       = s.tiles       or {}
            cellOf      = s.cellOf      or {}
            seats       = s.seats       or {}
            usedSpots   = s.usedSpots   or {}
            usedClasses = s.usedClasses or {}
            status      = s.status      or "EMPTY"
        end
    end

    addContextMenuItem("Rebuild Fellstone table", function() buildTable() end, false, true)

    -- Objects restored from a save file are not reliably addressable on the
    -- first frame, so give them a moment before deciding whether to build.
    Wait.frames(function()
        computeAllAreas()
        if #getObjectsWithTag(TAG_TILE) >= GRID_W * GRID_H then
            setStatus("Ready")
            refreshSeats()
        else
            enqueue("build")
        end
    end, 5)
end
