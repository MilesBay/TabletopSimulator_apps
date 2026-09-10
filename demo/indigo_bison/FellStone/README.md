
# demo of The Dungeon of FellStone 10/09/2026

![](result.png)

## Install

1. New game in TTS → pick a **large rectangular table** (Table_Custom or Table_Poker). Round tables work but the six starting spots sit closer together.
2. `~` to open the console, then **Scripting** (or Modding → Scripting).
3. Paste `fellstone_demo_1009.lua` into the **Global** tab.
4. Paste `fellstone_demo_1009.xml` into the **XML** tab.
5. **Save & Play**.

The table builds itself. It takes roughly 15–20 seconds — the script deliberately spends a frame per card, because dealing 49 cards in one frame is what makes them land in the wrong slots.

Nothing needs a GUID. Every component is spawned from TTS's built-in objects, so there is no setup step where you right-click things and copy IDs.

## What you should see

- A 7×7 grid of face-down cards, locked, in the middle.
- A face-down draw pile to the right of the board (55 cards).
- Three bags in a column to the right of that: Piece Reserve, Dice Reserve, Class Reserve.
- Two combat slots to the left of the board.
- Six starting spots around the rim of the board — empty until players sit.
- A coloured name label in front of each seat.

Then sit down. You should get a coloured pawn on a starting spot, a health die showing 4 beside your play area, five cards in your hand that only you can see, and a message naming your class.

Stand up (or switch to Grey) and all three go back into the bags, and your class becomes available again.

## Card budget

Three standard 52-card decks, spawned by the script:

| Deck | Use |
|---|---|
| A + B, merged into 104 | 49 dungeon tiles + 55-card draw pile |
| C, 52 | 30 combat cards (6 classes × 5); 22 spare are destroyed |

Each class hand is 3 class cards + Dodge + Hidden Blade. The script takes 30 cards off deck C and **renames** them, so a card reads "Mage - Fireball" while the poker rank stays visible underneath as a serial number. That is why the rank→class mapping from your spec isn't in the code: renaming gets you readable placeholders instead of a mapping everyone has to memorise. If you'd rather match by rank, `makeClassDecks()` is the only function that changes.

## Configuration

Everything adjustable is in section `[1] CONFIG`:

| Setting | What it does |
|---|---|
| `GRID_W`, `GRID_H` | Try `5, 5` for faster test runs. Spacing, snap points and starting spots all follow automatically. |
| `TILE_SCALE` | Card size. Spacing is derived from it, so shrinking cards never breaks alignment. |
| `SEAT_INSET` | Raise if a player area overlaps the board; lower if it hangs off the table edge. |
| `LOCK_HEALTH_DIE` | `true` (default) means the die can't be knocked or re-rolled; change HP from its right-click menu. `false` gives you a normal rollable die. |
| `CLASSES` | Class names and their three card names. |
| `MANIFEST` | Empty strings mean "spawn a placeholder". When you have real art, paste the GUID here and nothing else changes. |

## Troubleshooting

**"No hand zone for: Brown, Teal…"** in the console — normal. The script only builds player areas for the six colours in `SEAT_COLORS`, and only if that colour has a hand zone. Every default table has them for the standard colours.

**A player area sits on top of the board** — your table is smaller than the layout assumes. Raise `SEAT_INSET`, or lower `TILE_SCALE` to about `0.5`.

**Cards fall off the table during build** — the staging spot is at `gridPos(RIGHT_COL, GRID_H)`. On a small round table, move `RIGHT_COL` down to about `GRID_W + 2`.

**Build ran twice / duplicate objects** — press **Clear Table**, then **Build**. Teardown only destroys objects tagged `Fellstone`, so anything you placed by hand is safe.

**The class deck didn't reach my hand** — check the console for a take failure. The most likely cause is that a previous player left mid-build and the class deck was still being reassembled; the job queue serialises these, but a hard disconnect can interrupt it.

## Not in this version

Turn order (`Turns`), tile flipping, movement rules, the reference panel, and combat resolution. The combat *slots* and the reveal button exist and work; nothing else about combat does.

The tile data structure is already what those features need: `tiles[col][row] = guid` plus `cellOf[guid] = {col, row}`, both persisted through save/load. Movement and "flip the card you land on" can be built on top without touching the build code.

One decision that's already made for you: the tiles are **locked**, and a locked card can't be flipped by hand in TTS. So flipping has to go through script — most likely `card.addContextMenuItem("Flip", ...)` added in the deal callback, or triggered automatically when a piece is dropped on a cell.
