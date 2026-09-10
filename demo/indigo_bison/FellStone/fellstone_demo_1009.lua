--============================================================================
-- The Dungeon of Fellstone -- Global.lua
-- v2: build + rules. Dungeon resolution and combat are now implemented.
--
-- Paste into: Tabletop Simulator -> Scripting -> Global (Lua tab)
-- Companion panel goes in the XML tab -- see fellstone_1109.xml
--
-- What v1 did (unchanged in shape, edited in detail):
--   0  standard playing cards supply every component
--   1  one layout formula + one MANIFEST
--   2  self-building dungeon on load
--   3  pieceBag / diceBag / classBag
--   4  per-seat player areas with owned hand zones
--   5  automatic seating
--
-- What v2 adds:
--   6  card identity: every dungeon card and every combat card carries a role
--   7  turn order through the built-in Turns system
--   8  movement: drag your pawn up to MAX_MOVE cells, then the tile resolves
--   9  tile resolution: Room / Rest / six Traps / Fellstone Wraith
--  10  combat: player vs Wraith and player vs player, with all abilities
--  11  health on a d4, damage, elimination, last adventurer standing
--  12  hand economy: discard, refresh, and discard-becomes-hand recycling
--
-- Rules source: CARDS.md (card table) and the GDD (turn structure). Where the
-- two disagree the CARDS.md numbers win, because those are the ones that were
-- costed against three physical decks.
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
local MAX_MOVE  = 3     -- "move up to 3 spaces" (GDD, Gameplay)
local QUAKE_RADIUS = 3  -- Q-spade trap reaches this far

-- How far in from a player's hand zone their play area sits, and how far
-- the die / discard sit either side of it. Raise SEAT_INSET if a player area
-- overlaps the board on your table; lower it if it hangs off the edge.
local SEAT_INSET  = 5.0
local SEAT_SPREAD = 3.2

-- A locked health die cannot be knocked or re-rolled by accident, so the
-- number everyone reads stays true. The script unlocks it to set HP and
-- re-locks it afterwards.
local LOCK_HEALTH_DIE = true

-- Dungeon cards are tinted cool grey and combat cards are left alone, which
-- reproduces the black/red split from CARDS.md without depending on which
-- poker face the engine happens to hand us. A captured Wraith keeps the
-- dungeon tint, so you can still see at a glance which cards in a hand came
-- off the board.
local TINT_CARDS   = true
local DUNGEON_TINT = { 0.62, 0.66, 0.74 }

local SEAT_COLORS = { "White", "Red", "Yellow", "Green", "Blue", "Purple" }

local FACE_DOWN = { x = 0, y = 180, z = 180 }
local FACE_UP   = { x = 0, y = 180, z = 0   }

local TAG_BUILD  = "Fellstone"     -- everything this script spawns
local TAG_TILE   = "DungeonTile"   -- the 49 grid cards
local TAG_COMBAT = "CombatCard"    -- the 30 class cards

local MSG_GOOD = { 0.45, 0.95, 0.55 }
local MSG_WARN = { 1.00, 0.80, 0.30 }
local MSG_BAD  = { 1.00, 0.45, 0.45 }
local MSG_INFO = { 0.85, 0.88, 1.00 }


--============================================================================
-- [2] CARD DEFINITIONS -- the rules table, transcribed from CARDS.md
--
-- `face` is the notional playing card. The engine shuffles its built-in deck
-- on spawn and gives no reliable way to ask a card what it is, so the script
-- assigns roles itself and writes them into each card's name and description.
-- The pip you see is therefore a serial number; the tooltip is authoritative.
-- If you later switch to real art, `dungeonManifest()` and `CLASSES` are the
-- only two places that need to know anything.
--============================================================================

-- Rank sets the type. Suit is just a copy number, except on traps.
local ROOM_RANKS   = { "A", "2", "3", "4", "5" }   -- 5 x 2 suits x 3 decks = 30
local WRAITH_RANKS = { "6", "7", "8", "9" }        -- 4 x 2 suits x 3 decks = 24
local REST_RANK    = "K"                           -- 1 x 2 suits x 3 decks =  6
local COPIES       = 3                             -- three standard decks

local TRAPS = {
    { face = "10S", key = "steal",   name = "Trap - Pickpocket",
      text = "Steal a random card from another player's hand." },
    { face = "10C", key = "bury",    name = "Trap - Cache",
      text = "Put a random card from your hand under this tile." },
    { face = "JS",  key = "skip",    name = "Trap - Snare",
      text = "Your next turn is skipped." },
    { face = "JC",  key = "refresh", name = "Trap - Wellspring",
      text = "Refresh your hand." },
    { face = "QS",  key = "quake",   name = "Trap - Collapse",
      text = "Every face-up tile within 3 cells returns to the draw pile, is shuffled, and is redealt face down. This one included." },
    { face = "QC",  key = "swap",    name = "Trap - Displacement",
      text = "Swap positions with another player." },
}

-- Suit is your class. Rank is your power. Both hands total 15 power, so the
-- classes differ only in what their abilities do.
local CLASSES = {
    {
        name = "Mage", suit = "H",
        cards = {
            { rank = "A", power = 1, ability = "dodge",        label = "Dodge",
              text = "You lose no health this combat." },
            { rank = "2", power = 2, ability = "counterspell", label = "Counterspell",
              text = "Your opponent's ability does not resolve." },
            { rank = "3", power = 3, ability = "hiddenblade",  label = "Hidden Blade",
              text = "Becomes Power 6 if your opponent's power is 4 or more." },
            { rank = "4", power = 4, ability = "thunderslash", label = "Thunder Slash",
              text = "+1 power per face-up monster tile adjacent to you." },
            { rank = "5", power = 5, ability = "fireball",     label = "Fireball",
              text = "If you win, your opponent loses 2 health." },
        },
    },
    {
        name = "Paladin", suit = "D",
        cards = {
            { rank = "A", power = 1, ability = "dodge",        label = "Dodge",
              text = "You lose no health this combat." },
            { rank = "2", power = 2, ability = "defensive",    label = "Defensive Stance",
              text = "You win ties." },
            { rank = "3", power = 3, ability = "hiddenblade",  label = "Hidden Blade",
              text = "Becomes Power 6 if your opponent's power is 4 or more." },
            { rank = "4", power = 4, ability = "riposte",      label = "Riposte",
              text = "If you lose, your opponent also loses 1 health." },
            { rank = "5", power = 5, ability = "authority",    label = "Authority",
              text = "If you win, steal a random card from your opponent's hand." },
        },
    },
}

-- Six seats, three of each class, so 30 red cards is exactly the budget.
local SEATS_PER_CLASS = 3

-- The full 78-card dungeon, as a flat list of role descriptors.
local function dungeonManifest()
    local list = {}
    local function add(entry)
        for _ = 1, COPIES do
            for _, suit in ipairs({ "S", "C" }) do
                local copy = {}
                for k, v in pairs(entry) do copy[k] = v end
                copy.face = entry.rank .. suit
                table.insert(list, copy)
            end
        end
    end

    for _, rank in ipairs(ROOM_RANKS) do
        add({ role = "room", rank = rank, name = "Room",
              text = "An empty tile. Nothing happens." })
    end
    for _, rank in ipairs(WRAITH_RANKS) do
        local power = tonumber(rank) - 4      -- 6 is Power 2, 9 is Power 5
        add({ role = "wraith", rank = rank, power = power,
              name = "Fellstone Wraith - Power " .. power,
              text = "No ability. Play one combat card against it; ties go to you. "
                  .. "Beat it and it joins your hand as a combat card of that power. "
                  .. "Lose and you take 1 damage and it stays face up." })
    end
    add({ role = "rest", rank = REST_RANK, name = "Rest",
          text = "Stop here and refresh your hand. The tile is then discarded and the cell counts as a Room." })

    -- Traps carry their own suit, so they are added by hand rather than in pairs.
    for _, trap in ipairs(TRAPS) do
        for _ = 1, COPIES do
            table.insert(list, {
                role = "trap", trap = trap.key, face = trap.face,
                name = trap.name, text = trap.text,
            })
        end
    end

    return list
end


--============================================================================
-- [3] MANIFEST -- one place to point at real components later
--============================================================================

local MANIFEST = {
    dungeonDeck = "",   -- becomes the draw pile once the grid is dealt
    pieceBag    = "",
    diceBag     = "",
    classBag    = "",
}


--============================================================================
-- [4] STATE
--============================================================================

local built       = {}   -- logical name -> GUID of the live object
local tiles       = {}   -- tiles[col][row] = card GUID (nil = cleared cell)
local cellOf      = {}   -- card GUID -> { col, row }
local tileInfo    = {}   -- card GUID -> { role, power, trap, face, name, faceUp }
local cardInfo    = {}   -- card GUID -> { kind, class, power, ability, label }
local buried      = {}   -- tile GUID -> card GUID stashed under it
local seats       = {}   -- colour -> { spot, class, piece, die, hp, col, row, alive }
local usedSpots   = {}   -- spot index -> colour
local classCount  = {}   -- class name -> how many seats have taken it
local areas       = {}   -- colour -> { play, die, discard, yaw }
local pieceOwner  = {}   -- pawn GUID -> colour
local skipNext    = {}   -- colour -> true if their next turn is skipped
local status      = "EMPTY"

local turnState   = { color = nil, moved = false, busy = false }
local combat      = nil  -- see Game.beginWraithCombat / Game.beginDuel

local jobQueue    = {}
local workerBusy  = false

local Game = {}   -- gameplay namespace: members resolve at call time, so the
                  -- mutually recursive turn / combat / trap functions can be
                  -- written in whatever order reads best.


--============================================================================
-- [5] LAYOUT -- every position on the table derives from gridPos()
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

-- Pawns ride slightly above the tiles so they never fight for the same space.
local function pawnPos(col, row)
    local p = gridPos(col, row)
    return { x = p.x, y = p.y + 0.6, z = p.z }
end

local MID_ROW   = math.floor((GRID_H + 1) / 2)
local RIGHT_COL = GRID_W + 2.6
local Layout    = {}

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
    -- Six starting spots around the rim. These are real (integer) cells that
    -- happen to sit outside the board, so ordinary grid distance works from a
    -- starting spot without any special case: stepping onto the board costs 1.
    Layout.startCells = {
        { col = 2,          row = 0          },
        { col = GRID_W - 1, row = 0          },
        { col = GRID_W + 1, row = MID_ROW    },
        { col = GRID_W - 1, row = GRID_H + 1 },
        { col = 2,          row = GRID_H + 1 },
        { col = 0,          row = MID_ROW    },
    }
end


--============================================================================
-- [6] SMALL HELPERS
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

local function live(guid)
    if guid == nil then return nil end
    local obj = getObjectFromGUID(guid)
    if obj == nil or obj.isDestroyed() then return nil end
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

local function onBoard(col, row)
    return col >= 1 and col <= GRID_W and row >= 1 and row <= GRID_H
end

-- Grid distance. No walls exist, so the shortest legal path is always the
-- Manhattan distance and there is nothing to search.
local function cellDistance(a, b)
    return math.abs(a.col - b.col) + math.abs(a.row - b.row)
end

local function nearestCell(pos)
    local best, bestD
    for col = 1, GRID_W do
        for row = 1, GRID_H do
            local p  = gridPos(col, row)
            local dx, dz = pos.x - p.x, pos.z - p.z
            local d  = dx * dx + dz * dz
            if bestD == nil or d < bestD then
                best, bestD = { col = col, row = row }, d
            end
        end
    end
    return best
end

local function setStatus(text)
    status = text
    pcall(function() UI.setValue("fellstoneStatus", text) end)
end

local function setBanner(text)
    pcall(function() UI.setValue("fellstoneTurn", text) end)
end

local function tint(color)
    local ok, c = pcall(function() return Color.fromString(color) end)
    if ok then return c end
    return { 1, 1, 1 }
end

-- Several resolution paths have both a callback and a timeout fallback, in
-- case a player dismisses a dialog. Wrapping the continuation makes the
-- second caller a no-op, so a dismissed dialog can never resolve a tile twice.
local function once(fn)
    local fired = false
    return function(...)
        if fired then return end
        fired = true
        if fn then fn(...) end
    end
end

local function shuffled(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

local function livingColors()
    local out = {}
    for _, color in ipairs(SEAT_COLORS) do
        local rec = seats[color]
        if rec and rec.alive then table.insert(out, color) end
    end
    return out
end

local function claimSpot()
    for i = 1, #Layout.startCells do
        if usedSpots[i] == nil then return i end
    end
    return nil
end

local function claimClass()
    local free = {}
    for _, class in ipairs(CLASSES) do
        if (classCount[class.name] or 0) < SEATS_PER_CLASS then
            table.insert(free, class)
        end
    end
    if #free == 0 then return nil end
    return free[math.random(#free)]
end

-- A single readable line for a card, used in the choose-a-card dialog.
local function cardLabel(guid)
    local info = cardInfo[guid]
    if info == nil then return "Unknown card" end
    if info.kind == "monster" then
        return "Wraith - Power " .. info.power .. "  (no ability)"
    end
    return info.label .. "  -  Power " .. info.power
end


--============================================================================
-- [7] BUILD -- one coroutine, because every spawn needs frames to land
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
    built, tiles, cellOf, tileInfo, cardInfo, buried = {}, {}, {}, {}, {}, {}
    seats, usedSpots, classCount, pieceOwner, skipNext = {}, {}, {}, {}, {}
    turnState = { color = nil, moved = false, busy = false }
    combat = nil
    Turns.enable = false
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

-- Three standard 52-card decks merged into one 156-card source: 78 become the
-- dungeon, 30 become the six starting hands, and 48 are destroyed.
local function makeSourceDeck()
    local piles = {}
    for i = 1, COPIES do
        local d = spawnTagged({
            type     = "Deck",
            position = { Layout.staging.x, Layout.staging.y + (i - 1) * 4, Layout.staging.z },
            sound    = false,
        })
        if d == nil then return nil end
        table.insert(piles, d)
    end

    local merged = piles[1]
    for i = 2, #piles do
        merged = merged.putObject(piles[i])
        pause(4)
    end
    merged.addTag(TAG_BUILD)
    merged.setName("Fellstone Source")
    pause(3)
    return merged
end

-- Stamp a dungeon role onto a physical card and remember it.
local function dressDungeonCard(card, entry)
    local guid = card.getGUID()
    card.setName(entry.name)
    card.setDescription(entry.face .. "  -  " .. entry.text)
    card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
    card.addTag(TAG_TILE)
    card.addTag(TAG_BUILD)
    if TINT_CARDS then card.setColorTint(DUNGEON_TINT) end
    tileInfo[guid] = {
        role   = entry.role,
        power  = entry.power,
        trap   = entry.trap,
        face   = entry.face,
        name   = entry.name,
        text   = entry.text,
        faceUp = false,
    }
    return guid
end

-- Deal 49 dungeon cards to the grid and stack the other 29 as the draw pile.
local function dealDungeon(source)
    local manifest = shuffled(dungeonManifest())
    local need     = GRID_W * GRID_H

    tiles, cellOf = {}, {}
    for col = 1, GRID_W do tiles[col] = {} end

    for i = 1, need do
        local col   = ((i - 1) % GRID_W) + 1
        local row   = math.floor((i - 1) / GRID_W) + 1
        local entry = manifest[i]
        local c, r  = col, row   -- captured per iteration by the callback below

        source.takeObject({
            position = gridPos(c, r),
            rotation = FACE_DOWN,
            smooth   = false,
            callback_function = function(card)
                local guid = dressDungeonCard(card, entry)
                card.setLock(true)
                tiles[c][r]  = guid
                cellOf[guid] = { col = c, row = r }
            end,
        })
        -- One card per frame. Dealing all 49 in one frame is the single most
        -- common cause of cards landing in the wrong slot.
        pause(1)
    end
    pause(4)

    -- The remainder of the manifest becomes the draw pile.
    local pile = nil
    for i = need + 1, #manifest do
        local entry = manifest[i]
        local card  = source.takeObject({
            position = { Layout.staging.x + 4, Layout.staging.y + 0.4, Layout.staging.z },
            rotation = FACE_DOWN,
            smooth   = false,
        })
        pause(2)
        if card then
            dressDungeonCard(card, entry)
            if pile == nil then pile = card else pile = pile.putObject(card) end
            pause(2)
        end
    end
    pause(3)

    if pile and not pile.isDestroyed() then
        pile.addTag(TAG_BUILD)
        pile.setName("Draw Pile")
        pile.setDescription("Face-down dungeon cards not yet on the board.")
        pile.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
        pile.setPosition(Layout.drawPile)
        pile.setRotation(FACE_DOWN)
        pile.setLock(true)
        built.dungeonDeck = pile.getGUID()
    end
end

-- Six 5-card class decks: three Mage, three Paladin. Each card is renamed and
-- registered, so the rest of the script never has to inspect a card face.
local function makeClassDecks(source, classBag)
    for _, class in ipairs(CLASSES) do
        for copy = 1, SEATS_PER_CLASS do
            local pile = nil
            for k, def in ipairs(class.cards) do
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
                if card then
                    local guid = card.getGUID()
                    card.setName(class.name .. " - " .. def.label)
                    card.setDescription(def.rank .. class.suit
                        .. "  -  Power " .. def.power .. ". " .. def.text)
                    card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
                    card.addTag(TAG_BUILD)
                    card.addTag(TAG_COMBAT)
                    cardInfo[guid] = {
                        kind    = "combat",
                        class   = class.name,
                        power   = def.power,
                        ability = def.ability,
                        label   = def.label,
                        face    = def.rank .. class.suit,
                    }
                    if pile == nil then pile = card else pile = pile.putObject(card) end
                    pause(3)
                end
            end

            if pile and not pile.isDestroyed() then
                pile.setName(class.name)
                pile.setDescription(class.name .. " starting hand (" .. copy .. " of "
                    .. SEATS_PER_CLASS .. ")")
                pile.addTag(TAG_BUILD)
                classBag.putObject(pile)
                pause(4)
            end
        end
    end

    -- 48 cards of the three decks are spare. Nothing needs them, so they go.
    if source and not source.isDestroyed() then source.destruct() end
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
        -- Health is 4 and counts down, so a d4 is the die the rules ask for.
        local die = spawnTagged({
            type     = "Die_4",
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
-- [8] PLAYER AREAS
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

-- Discard slot as a real scripting zone, so the recycling rule can read
-- exactly what is in it rather than guessing from a position.
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

-- A snap point on every cell and every starting spot, so a dragged pawn lands
-- cleanly and the drop handler rarely has to correct anything.
local function boardSnapPoints(snaps)
    for col = 1, GRID_W do
        for row = 1, GRID_H do
            local p = pawnPos(col, row)
            table.insert(snaps, { position = { p.x, p.y - 0.4, p.z } })
        end
    end
    for _, cell in ipairs(Layout.startCells) do
        local p = pawnPos(cell.col, cell.row)
        table.insert(snaps, { position = { p.x, p.y - 0.4, p.z } })
    end
end


--============================================================================
-- [9] HEALTH, HANDS AND THE DISCARD PILE
--============================================================================

function Game.setHp(color, hp)
    local rec = seats[color]
    if rec == nil then return end
    rec.hp = hp

    local die = live(rec.die)
    if die then
        die.setLock(false)
        die.setRotationValue(math.max(1, math.min(4, hp)))
        if LOCK_HEALTH_DIE then
            Wait.time(function()
                local d = live(rec.die)
                if d then d.setLock(true) end
            end, 1.5)
        end
    end
end

function Game.discardZone(color)
    return live(built["discard_" .. color])
end

function Game.discardedCards(color)
    local zone = Game.discardZone(color)
    if zone == nil then return {} end
    local out = {}
    for _, obj in ipairs(zone.getObjects(true)) do
        if obj.type == "Card" then table.insert(out, obj) end
    end
    return out
end

-- Move a used card to this seat's discard slot, face up.
function Game.discardCard(color, card)
    if card == nil or card.isDestroyed() then return end
    local a = areas[color]
    local pos = a and a.discard or Layout.staging
    card.setLock(false)
    card.setRotationSmooth(FACE_UP, false, false)
    card.setPositionSmooth({ pos.x, pos.y + 0.4, pos.z }, false, false)
end

-- "When a player's hand is empty, their discard pile is now their hand again."
function Game.recycleIfEmpty(color, done)
    Wait.time(function()
        local hand = Player[color].getHandObjects()
        if #hand == 0 then
            local n = Game.refreshHand(color)
            if n > 0 then
                broadcastToAll(color .. " has run out of cards and takes their discard pile back into hand.", MSG_INFO)
            end
        end
        if done then done() end
    end, 1.2)
end

-- Trap J-club and the Rest tile both do this: everything in the discard slot
-- goes back to the hand.
function Game.refreshHand(color)
    local cards = Game.discardedCards(color)
    for _, card in ipairs(cards) do
        card.setLock(false)
        card.deal(1, color)
    end
    return #cards
end

function Game.handGuids(color)
    local out = {}
    for _, card in ipairs(Player[color].getHandObjects()) do
        if card.type == "Card" then table.insert(out, card.getGUID()) end
    end
    return out
end

-- Ask a player to pick one card out of their hand. The hand can shift between
-- building the list and the answer coming back, so the choice is resolved by
-- GUID, never by index into a stale list.
function Game.promptCard(color, prompt, callback)
    local guids = Game.handGuids(color)

    if #guids == 0 then
        local n = Game.refreshHand(color)
        if n == 0 then
            broadcastToAll(color .. " has no cards at all and cannot fight.", MSG_WARN)
            callback(nil)
            return
        end
        Wait.time(function() Game.promptCard(color, prompt, callback) end, 1.2)
        return
    end

    local labels = {}
    for _, guid in ipairs(guids) do table.insert(labels, cardLabel(guid)) end

    Player[color].showOptionsDialog(prompt, labels, 1, function(_, index)
        local guid = guids[index]
        callback(live(guid), guid)
    end)
end


--============================================================================
-- [10] TILES
--============================================================================

function Game.tileAt(col, row)
    if tiles[col] == nil then return nil end
    return tiles[col][row]
end

function Game.clearCell(col, row)
    local guid = Game.tileAt(col, row)
    if guid then
        cellOf[guid] = nil
        tileInfo[guid] = nil
    end
    if tiles[col] then tiles[col][row] = nil end
end

-- Locked cards cannot be flipped by hand, so flipping always goes through
-- here: unlock, turn, settle back onto the exact cell centre, re-lock.
function Game.flipTile(guid, faceUp, done)
    local card = live(guid)
    local info = tileInfo[guid]
    if card == nil or info == nil then
        if done then done() end
        return
    end

    local cell = cellOf[guid]
    card.setLock(false)
    card.setRotationSmooth(faceUp and FACE_UP or FACE_DOWN, false, false)
    info.faceUp = faceUp

    Wait.time(function()
        local c = live(guid)
        if c then
            if cell then c.setPosition(gridPos(cell.col, cell.row)) end
            c.setRotation(faceUp and FACE_UP or FACE_DOWN)
            c.setLock(true)
        end
        if done then done() end
    end, 0.9)
end

-- Face-up Wraith tiles orthogonally adjacent to a cell. Thunder Slash counts
-- these, and nothing else in the game does.
function Game.adjacentWraiths(col, row)
    local n = 0
    local steps = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
    for _, s in ipairs(steps) do
        local guid = Game.tileAt(col + s[1], row + s[2])
        local info = guid and tileInfo[guid]
        if info and info.faceUp and info.role == "wraith" then n = n + 1 end
    end
    return n
end

function Game.occupantOf(col, row, except)
    for _, color in ipairs(livingColors()) do
        local rec = seats[color]
        if color ~= except and rec.col == col and rec.row == row then return color end
    end
    return nil
end


--============================================================================
-- [11] TURNS
--============================================================================

function Game.rebuildTurnOrder()
    local order = livingColors()
    Turns.type  = 2      -- custom order, so eliminated seats simply drop out
    Turns.order = order
    Turns.enable = #order > 0
    return order
end

function Game.beginPlay()
    local order = Game.rebuildTurnOrder()
    if #order < 2 then
        Turns.enable = false   -- rebuildTurnOrder enables on one seat; undo that
        broadcastToAll("At least two adventurers are needed to start.", MSG_WARN)
        return false
    end
    Turns.turn_color = order[math.random(#order)]
    broadcastToAll("The dungeon awakens. " .. Turns.turn_color .. " goes first.", MSG_GOOD)
    return true
end

function Game.startTurn(color)
    turnState = { color = color, moved = false, busy = false }
    combat = nil

    if skipNext[color] then
        skipNext[color] = nil
        broadcastToAll(color .. " is snared and loses this turn.", MSG_WARN)
        Wait.time(function() Game.endTurn() end, 1.5)
        return
    end

    local rec = seats[color]
    local where = rec and onBoard(rec.col, rec.row)
        and (" You are on " .. rec.col .. "," .. rec.row .. ".")
        or  " You are still on the rim."
    setBanner(color .. "'s turn")
    broadcastToColor("Your turn. Drag your pawn up to " .. MAX_MOVE
        .. " cells, then the tile you land on resolves." .. where, color, MSG_INFO)
end

function Game.endTurn()
    turnState.busy = false
    combat = nil
    if Turns.enable then Turns.endTurn() end
end

-- Called at the end of every resolution path. Kept separate from endTurn() so
-- a trap or combat that fires mid-resolution cannot end the turn twice.
function Game.finishAction()
    if turnState.busy then return end
    turnState.busy = true
    Wait.time(function() Game.endTurn() end, 0.6)
end

function Game.isMyTurn(color)
    return Turns.enable and Turns.turn_color == color
end


--============================================================================
-- [12] MOVEMENT
--============================================================================

function Game.placePawn(color, col, row, smooth)
    local rec = seats[color]
    if rec == nil then return end
    rec.col, rec.row = col, row
    local piece = live(rec.piece)
    if piece then
        local p = pawnPos(col, row)
        if smooth then piece.setPositionSmooth(p, false, false) else piece.setPosition(p) end
    end
end

function Game.handlePawnDrop(color, piece)
    local rec = seats[color]
    if rec == nil then return end

    local target = nearestCell(piece.getPosition())
    local from   = { col = rec.col, row = rec.row }

    local function snapBack(message)
        if message then broadcastToColor(message, color, MSG_WARN) end
        Game.placePawn(color, from.col, from.row, true)
    end

    if not Game.isMyTurn(color) then
        return snapBack("Not your turn yet.")
    end
    if turnState.moved or turnState.busy then
        return snapBack("You have already moved this turn.")
    end

    local dist = cellDistance(from, target)
    if dist == 0 then
        return snapBack(nil)   -- a nudge, not a move: costs nothing
    end
    if dist > MAX_MOVE then
        return snapBack("That is " .. dist .. " cells. You may move up to " .. MAX_MOVE .. ".")
    end

    turnState.moved = true
    Game.placePawn(color, target.col, target.row, true)
    broadcastToAll(color .. " moves " .. dist .. " to " .. target.col .. "," .. target.row .. ".", tint(color))

    Wait.time(function() Game.resolveLanding(color, target.col, target.row) end, 0.7)
end


--============================================================================
-- [13] LANDING AND TILE RESOLUTION
--============================================================================

-- The order of business on landing: any player already here fights you first,
-- then whatever you are standing on resolves, then anything buried under the
-- tile is collected, then the turn ends.
function Game.resolveLanding(color, col, row)
    local rival = Game.occupantOf(col, row, color)
    if rival then
        Game.beginDuel(color, rival, function()
            Game.resolveTile(color, col, row)
        end)
        return
    end
    Game.resolveTile(color, col, row)
end

function Game.collectBuried(color, col, row, done)
    local tileGuid = Game.tileAt(col, row)
    local cardGuid = tileGuid and buried[tileGuid]
    local card     = cardGuid and live(cardGuid)
    if card == nil then
        if done then done() end
        return
    end
    buried[tileGuid] = nil
    card.setLock(false)
    card.deal(1, color)
    broadcastToAll(color .. " finds a card cached under this tile.", MSG_GOOD)
    if done then Wait.time(done, 0.8) end
end

function Game.resolveTile(color, col, row)
    local guid = Game.tileAt(col, row)
    local info = guid and tileInfo[guid]

    local afterwards = once(function()
        Game.collectBuried(color, col, row, function() Game.finishAction() end)
    end)

    if info == nil then
        broadcastToColor("An empty cell. Nothing happens.", color, MSG_INFO)
        return afterwards()
    end

    -- Already face up: only a surviving Wraith still does anything.
    if info.faceUp then
        if info.role == "wraith" then
            Game.beginWraithCombat(color, guid, afterwards)
        else
            broadcastToColor("You are standing on " .. info.name .. ". Nothing happens.", color, MSG_INFO)
            afterwards()
        end
        return
    end

    Game.flipTile(guid, true, function()
        broadcastToAll(color .. " reveals " .. info.name .. ".", tint(color))

        if info.role == "room" then
            afterwards()

        elseif info.role == "rest" then
            Player[color].showConfirmDialog(
                "Rest here? Your discard pile returns to your hand and this tile is discarded.",
                function()
                    local n = Game.refreshHand(color)
                    broadcastToAll(color .. " rests and takes " .. n .. " card(s) back into hand.", MSG_GOOD)
                    local card = live(guid)
                    Game.clearCell(col, row)
                    if card then card.setLock(false) card.destruct() end
                    afterwards()
                end)
            -- If the dialog is dismissed the tile simply stays face up and the
            -- cell keeps counting as a Rest for whoever comes next.
            Wait.time(function()
                if not turnState.busy then afterwards() end
            end, 20)

        elseif info.role == "trap" then
            Game.resolveTrap(color, col, row, guid, info, afterwards)

        elseif info.role == "wraith" then
            Game.beginWraithCombat(color, guid, afterwards)

        else
            afterwards()
        end
    end)
end


--============================================================================
-- [14] TRAPS
--============================================================================

function Game.otherLivingColors(color)
    local out = {}
    for _, c in ipairs(livingColors()) do
        if c ~= color then table.insert(out, c) end
    end
    return out
end

function Game.stealRandomCard(thief, victim)
    local guids = Game.handGuids(victim)
    if #guids == 0 then
        broadcastToAll(victim .. " has nothing to steal.", MSG_WARN)
        return false
    end
    local card = live(guids[math.random(#guids)])
    if card == nil then return false end
    card.setLock(false)
    card.deal(1, thief)
    broadcastToAll(thief .. " steals a card from " .. victim .. ".", MSG_WARN)
    return true
end

function Game.resolveTrap(color, col, row, guid, info, done)
    local key = info.trap
    done = once(done)

    if key == "steal" then
        local targets = Game.otherLivingColors(color)
        if #targets == 0 then return done() end
        Player[color].showOptionsDialog("Steal a random card from which adventurer?",
            targets, 1, function(target)
                Game.stealRandomCard(color, target)
                done()
            end)
        Wait.time(function() if not turnState.busy then done() end end, 20)

    elseif key == "bury" then
        local guids = Game.handGuids(color)
        if #guids == 0 then
            broadcastToColor("Nothing in hand to cache.", color, MSG_WARN)
            return done()
        end
        local pick = guids[math.random(#guids)]
        local card = live(pick)
        if card then
            local p = gridPos(col, row)
            card.setLock(false)
            card.setRotation(FACE_DOWN)
            card.setPosition({ p.x, p.y - 0.35, p.z })
            card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
            Wait.time(function()
                local c = live(pick)
                if c then c.setLock(true) end
            end, 0.8)
            buried[guid] = pick
            broadcastToAll(color .. " caches a card under this tile. Whoever lands here next picks it up.", MSG_WARN)
        end
        done()

    elseif key == "skip" then
        skipNext[color] = true
        broadcastToAll(color .. " is snared and will lose their next turn.", MSG_WARN)
        done()

    elseif key == "refresh" then
        local n = Game.refreshHand(color)
        broadcastToAll(color .. " draws a wellspring and takes " .. n .. " card(s) back into hand.", MSG_GOOD)
        done()

    elseif key == "swap" then
        local targets = Game.otherLivingColors(color)
        if #targets == 0 then return done() end
        Player[color].showOptionsDialog("Swap positions with which adventurer?",
            targets, 1, function(target)
                local me, them = seats[color], seats[target]
                if me and them then
                    local mc, mr = me.col, me.row
                    Game.placePawn(color,  them.col, them.row, true)
                    Game.placePawn(target, mc,       mr,       true)
                    broadcastToAll(color .. " and " .. target .. " are wrenched into each other's places.", MSG_WARN)
                end
                done()
            end)
        Wait.time(function() if not turnState.busy then done() end end, 20)

    elseif key == "quake" then
        broadcastToAll("The dungeon collapses around " .. col .. "," .. row .. ".", MSG_WARN)
        enqueue("quake", nil, { col = col, row = row, done = done })

    else
        done()
    end
end

-- Q-spade. Every face-up tile within QUAKE_RADIUS goes back into the draw
-- pile, the pile is shuffled, and the same cells are dealt again face down.
-- This one runs in the job queue because putting cards back into a deck and
-- taking them out again needs frames between every step.
function Game.runQuake(payload)
    local pile = resolve("dungeonDeck")
    if pile == nil then
        if payload.done then payload.done() end
        return
    end

    local hits = {}
    for col = 1, GRID_W do
        for row = 1, GRID_H do
            local guid = Game.tileAt(col, row)
            local info = guid and tileInfo[guid]
            if info and info.faceUp
               and cellDistance({ col = col, row = row }, payload) <= QUAKE_RADIUS then
                table.insert(hits, { col = col, row = row, guid = guid })
            end
        end
    end

    if #hits == 0 then
        if payload.done then payload.done() end
        return
    end

    pile.setLock(false)
    pause(2)

    for _, hit in ipairs(hits) do
        local card = live(hit.guid)
        if card then
            card.setLock(false)
            pause(1)
            pile.putObject(card)
            pause(3)
        end
        cellOf[hit.guid] = nil
        if tiles[hit.col] then tiles[hit.col][hit.row] = nil end
    end

    pile.shuffle()
    pause(5)

    for _, hit in ipairs(hits) do
        local c, r = hit.col, hit.row
        pile.takeObject({
            position = gridPos(c, r),
            rotation = FACE_DOWN,
            smooth   = false,
            callback_function = function(card)
                local guid = card.getGUID()
                local info = tileInfo[guid]
                if info then info.faceUp = false end
                card.setScale({ TILE_SCALE, TILE_SCALE, TILE_SCALE })
                card.setLock(true)
                tiles[c][r]  = guid
                cellOf[guid] = { col = c, row = r }
            end,
        })
        pause(3)
    end

    pause(3)
    local p = resolve("dungeonDeck")
    if p then
        p.setPosition(Layout.drawPile)
        p.setRotation(FACE_DOWN)
        p.setLock(true)
    end

    broadcastToAll(#hits .. " tile(s) were swallowed and redealt face down.", MSG_WARN)
    if payload.done then payload.done() end
end


--============================================================================
-- [15] COMBAT
--
-- Power is resolved in one pass so that neither side sees the other's
-- modified number before its own is computed:
--   1. Counterspell decides which abilities resolve at all.
--   2. Hidden Blade and Thunder Slash adjust power, both reading the
--      opponent's *printed* power, never the modified one.
--   3. Powers are compared; Defensive Stance decides ties.
--   4. Damage, then Fireball / Riposte / Authority.
--============================================================================

function Game.effectivePower(info, color, opponentBase, abilityLives)
    local p = info.power
    if not abilityLives then return p end
    if info.ability == "hiddenblade" and opponentBase >= 4 then
        p = 6
    elseif info.ability == "thunderslash" then
        local rec = seats[color]
        if rec then p = p + Game.adjacentWraiths(rec.col, rec.row) end
    end
    return p
end

-- Move a card to a combat slot, face up, so the table shows what was played.
function Game.showInSlot(card, index)
    if card == nil or card.isDestroyed() then return end
    local pos = Layout.combat[index]
    if pos == nil then return end
    card.setLock(false)
    card.setPositionSmooth({ pos.x, pos.y + 0.4, pos.z }, false, false)
    card.setRotationSmooth(FACE_UP, false, false)
end

function Game.damage(color, amount, source)
    local rec = seats[color]
    if rec == nil or not rec.alive or amount <= 0 then return end
    local hp = math.max(0, (rec.hp or START_HP) - amount)
    Game.setHp(color, hp)
    broadcastToAll(color .. " loses " .. amount .. " health" ..
        (source and (" to " .. source) or "") .. ". Now at " .. hp .. ".",
        hp > 0 and MSG_WARN or MSG_BAD)
    if hp <= 0 then Game.eliminate(color) end
end

-- ---- player vs Wraith -----------------------------------------------------

function Game.beginWraithCombat(color, tileGuid, done)
    local info = tileInfo[tileGuid]
    if info == nil or info.role ~= "wraith" then
        if done then done() end
        return
    end

    broadcastToAll(color .. " faces a Fellstone Wraith of Power " .. info.power .. ".", MSG_WARN)

    Game.promptCard(color, "Fellstone Wraith - Power " .. info.power
        .. ". Choose the card you play against it.", function(card, guid)
        if card == nil then
            Game.damage(color, 1, "the Wraith")
            if done then done() end
            return
        end

        local mine = cardInfo[guid] or { power = 0, label = "Unknown" }
        Game.showInSlot(card, 1)

        local wraithCard = live(tileGuid)
        local myPower = Game.effectivePower(mine, color, info.power, true)

        Wait.time(function()
            local won = myPower >= info.power   -- ties go to you
            broadcastToAll(color .. " plays " .. cardLabel(guid)
                .. " at effective Power " .. myPower
                .. " against Power " .. info.power .. ".", MSG_INFO)

            -- The played card is spent either way.
            Game.discardCard(color, card)

            if won then
                broadcastToAll(color .. " defeats the Wraith and takes it into hand.", MSG_GOOD)
                local cell = cellOf[tileGuid]
                if cell then Game.clearCell(cell.col, cell.row) end
                cardInfo[tileGuid] = {
                    kind  = "monster",
                    power = info.power,
                    label = "Wraith - Power " .. info.power,
                }
                tileInfo[tileGuid] = nil
                if wraithCard then
                    wraithCard.setLock(false)
                    wraithCard.removeTag(TAG_TILE)
                    wraithCard.addTag(TAG_COMBAT)
                    wraithCard.setName("Captured Wraith - Power " .. info.power)
                    wraithCard.setDescription("Power " .. info.power
                        .. ". No ability. Play it in combat in place of a combat card.")
                    wraithCard.deal(1, color)
                end
            else
                -- Dodge is the only thing that stops the hit.
                if mine.ability == "dodge" then
                    broadcastToAll(color .. " loses but dodges the blow.", MSG_INFO)
                else
                    Game.damage(color, 1, "the Wraith")
                end
                broadcastToAll("The Wraith stands. It stays face up for the next adventurer.", MSG_WARN)
            end

            Game.recycleIfEmpty(color, function()
                if done then done() end
            end)
        end, 1.6)
    end)
end

-- ---- player vs player -----------------------------------------------------

function Game.beginDuel(attacker, defender, done)
    broadcastToAll(attacker .. " and " .. defender .. " share a tile. Combat!", MSG_WARN)

    combat = {
        kind    = "pvp",
        order   = { attacker, defender },
        picks   = {},
        done    = done,
        pending = 2,
    }

    for i, color in ipairs(combat.order) do
        local slot = i
        Game.promptCard(color, "Combat against "
            .. (color == attacker and defender or attacker)
            .. ". Choose the card you play. Both are revealed together.",
            function(card, guid)
                if combat == nil or combat.kind ~= "pvp" then return end
                combat.picks[color] = { card = card, guid = guid, slot = slot }
                combat.pending = combat.pending - 1
                if card then
                    broadcastToAll(color .. " has chosen.", MSG_INFO)
                end
                if combat.pending <= 0 then Game.resolveDuel() end
            end)
    end
end

function Game.resolveDuel()
    local c = combat
    if c == nil or c.kind ~= "pvp" then return end
    combat = nil

    local a, b = c.order[1], c.order[2]
    local pa, pb = c.picks[a], c.picks[b]

    -- A player with literally no cards simply loses the exchange.
    if (pa == nil or pa.card == nil) and (pb == nil or pb.card == nil) then
        broadcastToAll("Neither adventurer can fight. The exchange is a stalemate.", MSG_WARN)
        if c.done then c.done() end
        return
    end
    if pa == nil or pa.card == nil then
        Game.damage(a, 1, b)
        if pb and pb.card then Game.discardCard(b, pb.card) end
        if c.done then c.done() end
        return
    end
    if pb == nil or pb.card == nil then
        Game.damage(b, 1, a)
        Game.discardCard(a, pa.card)
        if c.done then c.done() end
        return
    end

    local ia = cardInfo[pa.guid] or { power = 0, label = "Unknown" }
    local ib = cardInfo[pb.guid] or { power = 0, label = "Unknown" }

    Game.showInSlot(pa.card, 1)
    Game.showInSlot(pb.card, 2)

    -- 1. Counterspell. If both play it, both abilities are cancelled.
    local aLives = ib.ability ~= "counterspell"
    local bLives = ia.ability ~= "counterspell"

    -- 2. Power, each read against the opponent's printed power.
    local powerA = Game.effectivePower(ia, a, ib.power, aLives)
    local powerB = Game.effectivePower(ib, b, ia.power, bLives)

    Wait.time(function()
        broadcastToAll(a .. " plays " .. cardLabel(pa.guid) .. " (effective " .. powerA .. ")  vs  "
            .. b .. " plays " .. cardLabel(pb.guid) .. " (effective " .. powerB .. ").", MSG_INFO)

        local winner, loser, winInfo, loseInfo, winLives, loseLives

        if powerA == powerB then
            -- 3. Defensive Stance breaks the tie. If both hold it, it stays a tie.
            local aHolds = aLives and ia.ability == "defensive"
            local bHolds = bLives and ib.ability == "defensive"
            if aHolds and not bHolds then
                winner, loser = a, b
                winInfo, loseInfo, winLives, loseLives = ia, ib, aLives, bLives
            elseif bHolds and not aHolds then
                winner, loser = b, a
                winInfo, loseInfo, winLives, loseLives = ib, ia, bLives, aLives
            else
                broadcastToAll("A dead heat. Both adventurers take 1 damage.", MSG_WARN)
                if not (aLives and ia.ability == "dodge") then Game.damage(a, 1, "the clash") end
                if not (bLives and ib.ability == "dodge") then Game.damage(b, 1, "the clash") end
                Game.discardCard(a, pa.card)
                Game.discardCard(b, pb.card)
                Game.recycleIfEmpty(a, function()
                    Game.recycleIfEmpty(b, function() if c.done then c.done() end end)
                end)
                return
            end
        elseif powerA > powerB then
            winner, loser = a, b
            winInfo, loseInfo, winLives, loseLives = ia, ib, aLives, bLives
        else
            winner, loser = b, a
            winInfo, loseInfo, winLives, loseLives = ib, ia, bLives, aLives
        end

        broadcastToAll(winner .. " wins the exchange.", tint(winner))

        -- 4. Damage, then the win/lose abilities.
        local hit = 1
        if winLives and winInfo.ability == "fireball" then hit = 2 end
        if loseLives and loseInfo.ability == "dodge" then
            broadcastToAll(loser .. " dodges the blow entirely.", MSG_INFO)
        else
            Game.damage(loser, hit, winner)
        end

        if loseLives and loseInfo.ability == "riposte" then
            broadcastToAll(loser .. " ripostes.", MSG_WARN)
            Game.damage(winner, 1, loser .. "'s riposte")
        end

        if winLives and winInfo.ability == "authority" then
            Game.stealRandomCard(winner, loser)
        end

        Game.discardCard(a, pa.card)
        Game.discardCard(b, pb.card)
        Game.recycleIfEmpty(a, function()
            Game.recycleIfEmpty(b, function() if c.done then c.done() end end)
        end)
    end, 1.6)
end


--============================================================================
-- [16] ELIMINATION AND VICTORY
--============================================================================

function Game.eliminate(color)
    local rec = seats[color]
    if rec == nil or not rec.alive then return end
    rec.alive = false

    broadcastToAll(color .. " has fallen in the Dungeon of Fellstone.", MSG_BAD)

    local piece = live(rec.piece)
    if piece then
        piece.setLock(false)
        piece.destruct()
    end
    local die = live(rec.die)
    if die then
        die.setLock(false)
        die.destruct()
    end
    for _, card in ipairs(Player[color].getHandObjects()) do
        card.destruct()
    end
    for _, card in ipairs(Game.discardedCards(color)) do
        card.destruct()
    end

    Game.rebuildTurnOrder()
    Game.checkVictory()
end

function Game.checkVictory()
    local alive = livingColors()
    if #alive == 1 then
        Turns.enable = false
        setBanner(alive[1] .. " survives")
        setStatus("Finished")
        broadcastToAll(alive[1] .. " is the last adventurer standing. Fellstone is theirs.", MSG_GOOD)
        return true
    elseif #alive == 0 then
        Turns.enable = false
        setBanner("No survivors")
        setStatus("Finished")
        broadcastToAll("Fellstone claims them all.", MSG_BAD)
        return true
    end
    return false
end


--============================================================================
-- [17] SEATING
--============================================================================

local function seatPlayer(color)
    if seats[color] then return end

    local spot  = claimSpot()
    local class = claimClass()
    if spot == nil or class == nil then
        broadcastToColor("No free starting spot or class is available.", color, MSG_BAD)
        return
    end

    usedSpots[spot] = color
    classCount[class.name] = (classCount[class.name] or 0) + 1

    local cell   = Layout.startCells[spot]
    local record = {
        spot  = spot,
        class = class.name,
        hp    = START_HP,
        col   = cell.col,
        row   = cell.row,
        alive = true,
    }
    seats[color] = record

    local area = areas[color]

    -- 1. Piece, in that seat's colour, on a free starting spot.
    local pieceBag = resolve("pieceBag")
    local entry    = findInBag(pieceBag, color .. " Adventurer")
    if pieceBag and entry then
        local piece = pieceBag.takeObject({
            guid     = entry.guid,
            position = pawnPos(cell.col, cell.row),
            smooth   = false,
        })
        pause(3)
        if piece then
            record.piece = piece.getGUID()
            pieceOwner[piece.getGUID()] = color
        end
    end

    -- 2. Health die, showing 4.
    local diceBag = resolve("diceBag")
    if diceBag then
        local diePos = (area and area.die) or pawnPos(cell.col, cell.row)
        local die = diceBag.takeObject({ position = diePos, smooth = false })
        pause(4)
        if die then
            die.setName(color .. " HP")
            die.setColorTint(tint(color))
            die.setRotationValue(START_HP)
            pause(2)
            if LOCK_HEALTH_DIE then die.setLock(true) end
            die.addContextMenuItem("HP +1", function()
                local rec = seats[color]
                if rec and rec.alive then Game.setHp(color, math.min(4, (rec.hp or START_HP) + 1)) end
            end, true)
            die.addContextMenuItem("HP -1", function()
                local rec = seats[color]
                if rec and rec.alive then Game.damage(color, 1, "the dungeon") end
            end, true)
            record.die = die.getGUID()
        end
    end

    -- 3. A class deck, dealt into this seat's hand zone.
    local classBag  = resolve("classBag")
    local deckEntry = findInBag(classBag, class.name)
    if classBag and deckEntry then
        local deck = classBag.takeObject({
            guid     = deckEntry.guid,
            position = (area and area.play) or pawnPos(cell.col, cell.row),
            rotation = FACE_DOWN,
            smooth   = false,
        })
        pause(4)
        if deck then
            deck.deal(HAND_SIZE, color)
            pause(2)
        end
    end

    broadcastToColor(
        "You are the " .. class.name .. ". Health " .. START_HP .. ". "
        .. "On your turn: drag your pawn up to " .. MAX_MOVE
        .. " cells, and the tile you land on resolves automatically.",
        color, MSG_INFO)
    broadcastToAll(color .. " has joined as the " .. class.name .. ".", tint(color))

    if Turns.enable then Game.rebuildTurnOrder() end
end

local function unseatPlayer(color)
    local record = seats[color]
    if record == nil then return end

    local pieceBag = resolve("pieceBag")
    local diceBag  = resolve("diceBag")
    local classBag = resolve("classBag")

    local piece = live(record.piece)
    if piece then
        pieceOwner[record.piece] = nil
        piece.setLock(false)
        if pieceBag then pieceBag.putObject(piece) else piece.destruct() end
        pause(2)
    end

    local die = live(record.die)
    if die then
        die.setLock(false)
        die.setName("Health Die")
        die.setColorTint({ 1, 1, 1 })
        if diceBag then diceBag.putObject(die) else die.destruct() end
        pause(2)
    end

    -- Hand and discard back to reserve, reassembled into one class deck.
    local loose = {}
    for _, card in ipairs(Player[color].getHandObjects()) do table.insert(loose, card) end
    for _, card in ipairs(Game.discardedCards(color)) do table.insert(loose, card) end

    if #loose > 0 then
        local pile = nil
        for k, card in ipairs(loose) do
            card.setLock(false)
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

    usedSpots[record.spot] = nil
    classCount[record.class] = math.max(0, (classCount[record.class] or 1) - 1)
    seats[color] = nil
    skipNext[color] = nil

    if Turns.enable then Game.rebuildTurnOrder() end
    broadcastToAll(color .. " has left. The " .. record.class .. " is available again.", MSG_WARN)
end


--============================================================================
-- [18] JOB QUEUE
--
-- Seating touches bags, and every take needs frames, so seating has to run
-- in a coroutine. startLuaCoroutine takes a named function with no arguments,
-- so jobs go through a queue and one worker drains it in order. Two players
-- sitting down in the same frame can therefore never race each other.
--============================================================================

function enqueue(action, color, payload)
    table.insert(jobQueue, { action = action, color = color, payload = payload })
    if not workerBusy then
        workerBusy = true
        startLuaCoroutine(Global, "fellstoneWorker")
    end
end

local function doBuild()
    setStatus("Building...")
    teardown()
    pause(5)
    buildLayout()
    computeAllAreas()

    local snaps = {}
    local pieceBag = makeBag("pieceBag", "Piece Reserve")
    local diceBag  = makeBag("diceBag",  "Dice Reserve")
    local classBag = makeBag("classBag", "Class Reserve")

    local source = makeSourceDeck()
    if source then
        source.shuffle()
        pause(4)
        dealDungeon(source)
        if classBag then makeClassDecks(source, classBag) end
    end
    if pieceBag then fillPieceBag(pieceBag) end
    if diceBag  then fillDiceBag(diceBag)  end

    for _, color in ipairs(SEAT_COLORS) do spawnAreaMarkers(color, snaps) end
    spawnCombatSlots(snaps)
    boardSnapPoints(snaps)
    Global.setSnapPoints(snaps)

    Hands.enable = true
    Hands.hiding = 1     -- each hand visible only to its owner

    setStatus("Ready")
    setBanner("Waiting for players")
    broadcastToAll("Fellstone table is ready. Take a seat, then press Start Game.", MSG_GOOD)
    refreshSeats()
end

function fellstoneWorker()
    while #jobQueue > 0 do
        local job = table.remove(jobQueue, 1)
        if job.action == "seat" then
            seatPlayer(job.color)
        elseif job.action == "unseat" then
            unseatPlayer(job.color)
        elseif job.action == "quake" then
            Game.runQuake(job.payload)
        elseif job.action == "build" then
            doBuild()
        end
        pause(2)
    end
    workerBusy = false
    return 1
end


--============================================================================
-- [19] EVENTS
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

function onPlayerTurn(player, previous_player)
    if player == nil then return end
    Game.startTurn(player.color)
end

function onObjectDrop(player_color, obj)
    if obj == nil or obj.isDestroyed() then return end
    local owner = pieceOwner[obj.getGUID()]
    if owner == nil then return end

    if owner ~= player_color then
        -- Somebody else's adventurer. Put it back where it was.
        local rec = seats[owner]
        if rec then Game.placePawn(owner, rec.col, rec.row, true) end
        broadcastToColor("That is " .. owner .. "'s adventurer.", player_color, MSG_WARN)
        return
    end

    Game.handlePawnDrop(owner, obj)
end


--============================================================================
-- [20] UI HOOKS
--
-- An XML UI button is called as (player, value, id); an object button is
-- called as (obj, player_color, alt_click).
--============================================================================

function buildTable(player, value, id)
    if workerBusy then
        broadcastToAll("Already building.", MSG_WARN)
        return
    end
    enqueue("build")
end

function clearTable(player, value, id)
    teardown()
    setStatus("Empty")
    setBanner("Table cleared")
    broadcastToAll("Table cleared.", MSG_WARN)
end

function startGame(player, value, id)
    if status ~= "Ready" then
        broadcastToAll("Build the table first.", MSG_WARN)
        return
    end
    if Turns.enable then
        broadcastToAll("The game is already running.", MSG_WARN)
        return
    end
    for _, color in ipairs(livingColors()) do
        Game.setHp(color, START_HP)
    end
    if Game.beginPlay() then
        setStatus("In play")
    end
end

function endTurnButton(player, value, id)
    if player and not Game.isMyTurn(player.color) then
        broadcastToColor("It is not your turn.", player.color, MSG_WARN)
        return
    end
    Game.endTurn()
end

-- Escape hatch: if a dialog was dismissed and somebody is stuck waiting, this
-- forces the pending combat to resolve with whatever has been chosen.
function forceResolve(player, value, id)
    if combat and combat.kind == "pvp" then
        combat.pending = 0
        Game.resolveDuel()
    else
        broadcastToAll("Nothing is waiting to resolve.", MSG_WARN)
    end
end

function toggleReference(player, value, id)
    local shown = UI.getAttribute("fellstoneReference", "active")
    UI.setAttribute("fellstoneReference", "active", shown == "true" and "false" or "true")
end


--============================================================================
-- [21] LOAD / SAVE
--============================================================================

function onSave()
    return JSON.encode({
        built      = built,
        tiles      = tiles,
        cellOf     = cellOf,
        tileInfo   = tileInfo,
        cardInfo   = cardInfo,
        buried     = buried,
        seats      = seats,
        usedSpots  = usedSpots,
        classCount = classCount,
        pieceOwner = pieceOwner,
        skipNext   = skipNext,
        status     = status,
    })
end

function onLoad(saved_state)
    math.randomseed(os.time())
    buildLayout()

    if saved_state ~= nil and saved_state ~= "" then
        local ok, s = pcall(JSON.decode, saved_state)
        if ok and type(s) == "table" then
            built      = s.built      or {}
            tiles      = s.tiles      or {}
            cellOf     = s.cellOf     or {}
            tileInfo   = s.tileInfo   or {}
            cardInfo   = s.cardInfo   or {}
            buried     = s.buried     or {}
            seats      = s.seats      or {}
            usedSpots  = s.usedSpots  or {}
            classCount = s.classCount or {}
            pieceOwner = s.pieceOwner or {}
            skipNext   = s.skipNext   or {}
            status     = s.status     or "EMPTY"
        end
    end

    addContextMenuItem("Rebuild Fellstone table", function() buildTable() end, false, true)

    -- Objects restored from a save file are not reliably addressable on the
    -- first frame, so give them a moment before deciding whether to build.
    Wait.frames(function()
        computeAllAreas()
        if #getObjectsWithTag(TAG_TILE) >= GRID_W * GRID_H then
            setStatus(status == "In play" and "In play" or "Ready")
            setBanner(Turns.turn_color and (Turns.turn_color .. "'s turn") or "Waiting for players")
            refreshSeats()
        else
            enqueue("build")
        end
    end, 5)
end
