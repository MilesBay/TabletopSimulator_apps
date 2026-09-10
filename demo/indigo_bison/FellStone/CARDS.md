# Card Reference — The Dungeon of Fellstone (placeholder build)

Every component is a standard playing card. **Black = the dungeon. Red = your hand.**
A captured monster is black and stays black, so you can always see which cards in a hand were taken off the board.

Three standard decks: 78 black to the dungeon, 30 red to the six starting hands, 48 red destroyed.

---

## Dungeon cards — black (78)

Rank sets the type. Suit is just a copy number, except on traps.

### Room — `A ♠♣` `2 ♠♣` `3 ♠♣` `4 ♠♣` `5 ♠♣` (30 cards)
Empty tile. Nothing happens.

### Fellstone Wraith — `6 ♠♣` `7 ♠♣` `8 ♠♣` `9 ♠♣` (24 cards)
**Power = rank − 4** → 6 is Power 2, 9 is Power 5. Six copies at each power.
No ability. Play one combat card against it; ties go to you.
Beat it and it joins your hand as a combat card of that power. Lose and you take 1 damage, and the Wraith stays face up for the next player.

### Trap — `10 ♠♣` `J ♠♣` `Q ♠♣` (18 cards, 3 of each variant)

| Card | Effect |
|---|---|
| `10 ♠` | Steal a random card from another player's hand |
| `10 ♣` | Put a random card from your hand under this tile |
| `J ♠` | Your next turn is skipped |
| `J ♣` | Refresh your hand |
| `Q ♠` | Every face-up tile within 3 cells returns to the draw pile — shuffle, redeal face down, this one included |
| `Q ♣` | Swap positions with another player |

### Rest — `K ♠♣` (6 cards)
Stop here and refresh your hand. Once used, the tile is discarded and the cell counts as a Room.

---

## Combat cards — red (5 per player)

**Suit is your class. Rank is your power.** `4 ♥` beats `3 ♦` because 4 beats 3.
Both hands total 15 power, so classes differ only in what their abilities do.

### ♥ Mage

| Card | Power | Ability |
|---|---|---|
| `A ♥` Dodge | 1 | You lose no health this combat |
| `2 ♥` Counterspell | 2 | Your opponent's ability does not resolve |
| `3 ♥` Hidden Blade | 3 | Becomes Power 6 if your opponent's power is 4 or more |
| `4 ♥` Thunder Slash | 4 | +1 power per face-up monster tile adjacent to you |
| `5 ♥` Fireball | 5 | If you win, your opponent loses 2 health |

### ♦ Paladin

| Card | Power | Ability |
|---|---|---|
| `A ♦` Dodge | 1 | You lose no health this combat |
| `2 ♦` Defensive Stance | 2 | You win ties |
| `3 ♦` Hidden Blade | 3 | Becomes Power 6 if your opponent's power is 4 or more |
| `4 ♦` Riposte | 4 | If you lose, your opponent also loses 1 health |
| `5 ♦` Authority | 5 | If you win, steal a random card from your opponent's hand |

`A` and `3` are the two shared cards, on the same ranks in both suits.

---

## Resolution

- **Player vs player** — reveal together, compare power. Loser takes 1 damage. A tie costs **both** players 1 health.
- **Player vs Wraith** — your power must *match or beat* the Wraith's. Ties go to you.
- Used cards are discarded. When your hand is empty, your discard pile becomes your hand again.
- Health starts at 4, tracked on your d4. At 0 you are out.

---

## Reading a card in TTS

The face is unchanged — a flipped tile still shows `8 ♠`. The script writes the meaning into the card's name and description, so hovering it reads **Fellstone Wraith — Power 4**. The mapping above is the ground truth; the tooltip is the convenience layer.
