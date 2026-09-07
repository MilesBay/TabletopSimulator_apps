--==========================================================
-- The Dungeon of Fellstone — board setup
-- Paste into: Tabletop Simulator → Scripting → Global
-- The buttons live in the XML tab — see fellstone_ui.xml
--==========================================================

-- ---------- [1] CONFIG — this is the only part you must edit ----------

local DECK_GUID = "aaa111"   -- right-click the deck → Scripting → copy GUID

local GRID_W, GRID_H = 7, 7    -- change to 5,5 to test a smaller dungeon

-- Distance between card CENTRES, in TTS units (inches).
-- A standard poker card is roughly 2.3 wide x 3.2 tall, so these differ.
-- Step [7] below tells you how to measure yours exactly.
local SPACING_X = 2.6
local SPACING_Z = 3.6

-- Centre of the grid on the table. y should sit slightly above the surface.
local ORIGIN = { x = 0, y = 1.2, z = 0 }

local TILE_TAG = "DungeonTile"

-- Card rotation. z = 180 is what makes a card FACE DOWN in TTS.
-- y = 180 just controls which way the card's top edge points.
local FACE_DOWN = { x = 0, y = 180, z = 180 }

-- ---------- [2] STATE ----------

local dealtTiles = {}   -- GUIDs of the cards currently forming the board


-- ---------- [3] GRID MATH ----------
-- Converts a (col, row) pair into a world position, centred on ORIGIN.
-- Both dealBoard() and buildSnapPoints() call this, so the snap points
-- can never drift out of alignment with the cards.

local function gridPos(col, row)
    local ox = (GRID_W - 1) / 2
    local oz = (GRID_H - 1) / 2
    return {
        x = ORIGIN.x + (col - 1 - ox) * SPACING_X,
        y = ORIGIN.y,
        z = ORIGIN.z + (row - 1 - oz) * SPACING_Z,
    }
end


-- ---------- [4] DEAL THE BOARD ----------
-- Takes one card per frame. Doing all 49 in a single frame is the single
-- most common cause of "some cards spawned in the wrong place" bugs:
-- takeObject() needs a frame or more for each object to finish spawning.

function dealBoard()
    local deck = getObjectFromGUID(DECK_GUID)
    if deck == nil then
        broadcastToAll("Deck not found — check DECK_GUID.", { 1, 0.3, 0.3 })
        return
    end

    local need = GRID_W * GRID_H
    local have = #deck.getObjects()

    -- Leave at least 2 cards behind. When a container drops to one object,
    -- TTS destroys the container and your `deck` reference goes stale.
    if have < need + 2 then
        broadcastToAll(
            "Need " .. (need + 2) .. " cards, deck has " .. have .. ".",
            { 1, 0.3, 0.3 })
        return
    end

    if #getObjectsWithTag(TILE_TAG) > 0 then
        broadcastToAll("Board is already dealt. Clear it first.", { 1, 0.8, 0.3 })
        return
    end

    deck.shuffle()   -- deck.randomize() also works; it is the same as pressing R

    dealtTiles = {}
    local i = 1

    local function dealNext()
        local col = ((i - 1) % GRID_W) + 1
        local row = math.floor((i - 1) / GRID_W) + 1

        deck.takeObject({
            position = gridPos(col, row),
            rotation = FACE_DOWN,
            smooth   = false,   -- instant. `true` makes cards fly and shove each other
            callback_function = function(card)
                card.addTag(TILE_TAG)
                table.insert(dealtTiles, card.getGUID())
            end
        })

        i = i + 1
        if i <= need then
            Wait.frames(dealNext, 1)
        else
            broadcastToAll("Dungeon dealt: " .. GRID_W .. "x" .. GRID_H, { 0.4, 1, 0.4 })
        end
    end

    -- One frame of breathing room after the shuffle before we start taking.
    Wait.frames(dealNext, 1)
end


-- ---------- [5] CLEAR THE BOARD ----------
-- group() collects the loose cards back into a single deck, the same way
-- pressing G does. Then we merge that deck back into the original one.

function clearBoard()
    local tiles = getObjectsWithTag(TILE_TAG)
    if #tiles == 0 then return end

    for _, card in ipairs(tiles) do
        card.removeTag(TILE_TAG)
    end

    local grouped = group(tiles)

    Wait.frames(function()
        local deck = getObjectFromGUID(DECK_GUID)
        if deck == nil then return end
        for _, pile in ipairs(grouped) do
            if pile ~= deck and not pile.isDestroyed() then
                deck.putObject(pile)
            end
        end
    end, 2)   -- group() needs a frame or two to finish building the new deck

    dealtTiles = {}
end


-- ---------- [6] SNAP POINTS (optional but worth it) ----------
-- Creates one snap point per grid cell so that when a player picks a card
-- up and drops it, it lands back in the exact slot instead of drifting.
-- Click its button once; snap points persist in the save file, so you
-- do not need to run it again unless you change the grid or the spacing.

function buildSnapPoints()
    local pts = {}
    for row = 1, GRID_H do
        for col = 1, GRID_W do
            local p = gridPos(col, row)
            table.insert(pts, {
                position      = { p.x, ORIGIN.y - 0.2, p.z },  -- sit on the table
                rotation      = { 0, 180, 0 },
                rotation_snap = true,
                tags          = { TILE_TAG },   -- only tagged cards snap here
            })
        end
    end
    Global.setSnapPoints(pts)
    broadcastToAll(#pts .. " snap points created.", { 0.4, 1, 0.4 })
end


-- ---------- [7] MEASURING YOUR CARD (run once, then delete) ----------
-- Drop a single card on the table, put its GUID in here, and read the
-- numbers in the console (~ key). Set SPACING_X / SPACING_Z to those
-- numbers plus about 0.3 for a visible gap.

function measureCard()
    local card = getObjectFromGUID("REPLACE_ME")
    if card == nil then return end
    local b = card.getBounds()
    print("card width (x): " .. b.size.x .. "   depth (z): " .. b.size.z)
end


-- ---------- [8] LOAD / SAVE ----------
-- No button wiring here any more. The three buttons are declared in the
-- XML tab and call dealBoard / clearBoard / buildSnapPoints directly,
-- because a Global UI onClick defaults to the Global Lua script.
--
-- Signature note: an object button is called as (obj, player_color, alt_click);
-- an XML UI button is called as (player, value, id). None of our three
-- functions take arguments, so nothing needed changing — but keep this in
-- mind the first time you want to pass something in.

function onLoad(saved_state)
    if saved_state ~= nil and saved_state ~= "" then
        local ok, state = pcall(JSON.decode, saved_state)
        if ok and state and state.tiles then dealtTiles = state.tiles end
    end
end

function onSave()
    return JSON.encode({ tiles = dealtTiles })
end
