# Trading game: design

Working title, to be named. Draft of Nov 22, 2026: the decisions so far, and what is still to detail.

A single-player space trading game in B8Script, in the style of Elite and Trade Wars but not a copy of either. You start in debt with a small ship. You trade between generated star systems, smuggle when it pays, fight or flee, take contracts, upgrade your ship, and track down rare items that can only be bartered for. Turn-based throughout.

## Keeping it small

The game has to stay easy to write, read and test. These rules are part of the design:

- **A feature earns its place in the loop.** If it doesn't change what the player decides to do next, it waits for a later version.
- **One screen layout.** Every view fits the same panels; no special screens beyond the market, the chart and combat.
- **Easy numbers.** Pick quantities and methods that keep the maths simple in 16-bit cells (no multiply past 32,767, halving rather than odd divisions where it can be) and that pack neatly into the save code's printable characters (a value that fits 6 bits fits one character).
- **Generate, don't store.** The galaxy, its names and its prices come from the seed and the day. Only the player's own state is kept and saved.
- **Budgets.** The stripped `.B8S` at most 12 KB, and heap data at most 4 KB. If a feature doesn't fit, something else goes, or it waits.
- **Version 1 is the list under [Version 1](#version-1).** Everything under [Later](#later) stays out until version 1 plays well.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Setting | Space, with its own names and lore |
| 2 | Map | Star systems at positions on a star chart; you can jump to any system within your fuel range |
| 3 | Pressure and goal | A loan with interest at the start, plus rare items to collect. A rare item is found by chance, stays in its system, and can only be had by trading certain goods for it, not money |
| 4 | Economy | Prices set by each system's type, plus stock that drains as you trade and recovers each day. Events (shortages, booms) once the base plays well |
| 5 | Combat | A short turn-based duel |
| 6 | Law | Systems have a safety level; contraband pays well but brings police scans and fines |
| 7 | Growth | Ship upgrades, plus 3 or 4 ship classes to buy. Colonies later |
| 8 | Besides trading | Contracts (deliveries, passengers, bounties) and rumours |
| 9 | Screen | Fixed panels: status, the chart or the market, a message log. Only what changes is redrawn |
| 10 | Saving | A save code: the seed and the player's state, bit-packed into base-64 characters with a checksum |
| 11 | Names | System names generated from a syllable table |

## The loop

1. **Dock** at a system: see its market, its contracts and any rumours.
2. **Decide:** buy, sell, take a contract, barter for a rare item, refuel, upgrade, repay the loan.
3. **Pick a destination** on the chart, within fuel range.
4. **Jump:** a day passes. On the way there may be an **encounter** (pirates, police, a trader, nothing), settled by a duel, a bribe, a scan or flight.
5. **Arrive** and go back to 1.

The day count drives everything that changes over time: interest, stock recovery, contract deadlines.

## The parts

Each part says what is decided and what is left to detail.

### Map and systems

Decided (Nov 22).

- **64 systems**, so a system's number fits 6 bits: one save-code character.
- **The chart is the 56 × 16 main area.** x fits 6 bits and y 4.
- **Distance** is the real distance with x counted at half, since a screen cell is about twice as tall as it is wide. A jump costs its distance rounded up to a whole number, found by a small square-root loop (at most 16 tries). Fuel is in whole units, and the tank is the range: 7 to start, 14 at best (finished in Ship and upgrades).
- **Generation grows the map** from the home system at the centre: each new system goes within the starter's range of one already placed, and at least 2 cells from any other. Every system is then reachable by construction, with no search; some far arms need a bigger tank.
- **Safety by distance from home:** policed near the centre, frontier further out, lawless at the edges. It uses the same distance routine. Types are random.
- **The chart:** `@` for you; a visited system shows its type letter (A, M, I, H), an unvisited one `*`; capitals in range, lower case out of range (`.` for an unvisited one out of range). Two keys step the terminal's cursor through the systems in range, nearest first; the side panel shows the chosen system's name, type, safety and fuel cost; Return jumps.

### Economy

Decided (Nov 22).

**Goods.** Eight, one bit each where a set of goods is kept. Base prices in credits per tonne:

| Good | Base | | Good | Base |
|---|---|---|---|---|
| Food | 10 | | Medicine | 80 |
| Textiles | 20 | | Luxuries | 150 |
| Ore | 30 | | Narcotics (contraband) | 120 |
| Machinery | 60 | | Weapons (contraband) | 140 |

**System types.** Four. A type produces some goods (plentiful, so cheap) and consumes others (scarce, so dear); the rest are neither. Contraband goes by the system's safety level instead (see Law).

| | Food | Textiles | Ore | Machinery | Medicine | Luxuries |
|---|---|---|---|---|---|---|
| Agricultural | P | P | – | C | C | – |
| Mining | C | – | P | C | – | – |
| Industrial | C | – | C | P | – | – |
| High-tech | C | C | – | – | P | P |

**Price.** Each good in each system has a normal stock N: 50 where it is produced, 10 where it is consumed, 30 otherwise. The buy price is base × (3N − stock) ÷ 2N: 1.5 × base when the stock is empty, base at N, 0.5 × base at 2N. The type needs no price factor of its own: the stock does the work. Base at most 200 and N at most 50 keep base × 3N under 32,767.

**Wobble.** Up to ±10% a day, worked out from the seed, the system, the good and the day, so nothing is stored.

**Selling.** At 7⁄8 of the buy price, so buying and selling in one place loses money.

**Large trades.** Every tonne of one trade goes at the price the stock would give halfway through the trade.

**Stock.** A table of every system's stock (64 × 8 bytes), and each system's last-update day. On arrival the stock recovers by an eighth of its gap to N for each day since, for at most 8 days; only that one system is worked on. Trading moves the stock.

**Money.** Two cells, high × 10,000 + low, printed as the high part then the low part padded to four digits: up to 327 million. Adding and subtracting carry at 10,000. One transaction never passes 32,767: prices stay at most 300 and holds at most 100 tonnes, so every multiply fits one cell.

### Loan and rare items

Decided (Nov 22).

- **The loan:** 10,000 at the start, kept in one cell, never above 30,000. Each day adds 1% (debt ÷ 100). Pay it off in any amount when docked.
- **Not paying:** once the debt reaches 30,000, debt collectors turn up as encounters (pay, fight or flee) until it is paid. No game over for debt; it reuses the encounter and duel code.
- **Winning:** the loan repaid and all six rare items held. The score is the number of days taken: fewer is better.
- **Six rare items,** one bit each, so the collection is one save-code character. Trophies only: they do nothing once held (perks are under Later).
- **Where:** the seed places them in six systems, mostly frontier and lawless. You learn of one by docking there or from a rumour. An item stays in its system until you trade for it.
- **The price:** goods, not money. The seed sets two different goods for each item, 10 to 30 tonnes of each and at most 40 tonnes in all, sometimes one of them contraband. Hand them over and the item is yours.

### Combat

- **Decided:** a turn-based duel.
- **To detail:** the duel's state (range bands? hull and shields?); the actions (fire, missile, close in, pull back, flee, surrender or pay); what the enemy does; what you win (bounty, salvage) and lose (cargo, hull, the game); the kinds of opponent.

### Law and smuggling

- **Decided:** safety levels and contraband.
- **To detail:** the levels (say lawless, frontier, policed); how a scan works, and fines or seizure; whether a record or legal status lasts, and what it changes (police attack, ports refuse you).

### Ship and upgrades

Decided (Nov 22).

**Stats:** cargo, fuel tank, hull, laser level, shield level, missiles. (An escape pod is weighed under Combat, a hidden hold under Law.)

**Classes.** Every class can add up to 3 cargo pods (+10 tonnes each) and 2 tank upgrades (+2 each), so cargo never passes 100 and the tank never passes 14 (the economy and the map rely on both).

| Class | Cargo | Tank | Hull | Laser max | Shield max | Price |
|---|---|---|---|---|---|---|
| Courier (start) | 20 | 7 | 30 | 2 | 2 | — |
| Freighter | 50 | 8 | 50 | 2 | 3 | 9,000 |
| Raider | 30 | 10 | 60 | 4 | 4 | 12,000 |
| Clipper | 70 | 10 | 80 | 4 | 4 | 30,000 |

**Upgrades:** laser and shield levels up to the class's limit, at 1,000, 2,500, 5,000 and 9,000 a level; missiles at 500 each, at most 4; cargo pods at 1,500 each; tank upgrades at 2,000 each.

**Where:** fuel and repairs everywhere; upgrades at industrial and high-tech systems; ships only at high-tech.

**Buying a ship:** the old one is traded in at half its price. Upgrades carry over, cut to the new class's limits; if the cargo doesn't fit, the trade is refused.

**Running costs:** fuel 20 a unit, repairs 50 a hull point, the same everywhere.

### Contracts and rumours

- **Decided:** both.
- **To detail:** the contract kinds and how many you can hold (one, to keep the save code short?); pay and penalties; how rumours are made (a true tip about a price, or a rare item, or sometimes false?).

### Screen

- **Decided:** fixed panels in 80 × 24, using only the console subset.
- **To detail:** the layout, the keys for each view, what the message log keeps.

A first sketch:

```
+------------------------------------------------------------------------------+
| LAVE  Agri  Policed   Day 12   Cr 4,210   Debt 8,000   Fuel 7     Hull 100%   |
+------------------------------------------------------+-----------------------+
|                                                      | Cargo 12/20           |
|   star chart, or the market table, or the duel       |  Food        5        |
|                                                      |  Machinery   7        |
|                                                      |                       |
|                                                      | Contract              |
|                                                      |  8 Medicine to Diso   |
|                                                      |  by day 16            |
+------------------------------------------------------+-----------------------+
| messages: the last three lines of what happened                              |
| > command                                                                    |
+------------------------------------------------------------------------------+
```

### Saving

Decided (Nov 22), apart from the exact list of what is saved.

- **A save code** printed for the player to copy (most will copy and paste it; typing it is still bearable), and typed or pasted back to load. The galaxy comes from the seed, and stock levels are rebuilt on loading.
- **Packing:** every value goes in at its own bit width, through a small bit packer, and comes out 6 bits per character. Game numbers are never scaled to suit the code. About 210 bits, so about 35 characters.
- **Alphabet:** base 64 with `A`–`Z`, `a`–`z`, `0`–`9`, `-` and `_` (no `/`, which would need escaping in the program's strings).
- **A check character** at the end, so a mistyped or altered code is refused.
- **A light obfuscation,** so the code can't simply be decoded and edited: each 6-bit value is XORed with a stream from a small generator, started from a fixed key and a salt character at the front (so two nearly equal saves look different). It stops casual editing; anyone who reads the program can undo it, which is fine.
- **To detail:** exactly what is saved (seed, day, money, debt, position, cargo, ship and upgrades, legal status, rare items, contract, perhaps the visited systems).

### Names

- **Decided:** generated from a syllable table.
- **To detail:** the table; names for goods, ship classes and rare items (fixed lists).

## Version 1

The map, the economy, the loan, rare items, the duel, law and contraband, ship upgrades and classes, contracts and rumours, the panels, the save code, generated names.

## Later

Events (shortages, booms); colonies and outposts; perks for the rare items; ranks with titles; more opponent kinds; a second galaxy.

## Data budget (estimate)

| Data | Size |
|---|---|
| 64 systems × (position 2, type and safety 1, stock of 8 goods 8, last-update day 2) | 832 bytes |
| Visited systems, one bit each | 8 bytes |
| Goods, ships, upgrades, names: fixed tables | under 1 KB |
| The player's state | under 100 bytes |
