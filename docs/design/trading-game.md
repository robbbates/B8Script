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
| 10 | Saving | A save code: the seed and the player's state, printed as letters to type back in |
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

- **Decided:** you start with a loan and interest; rare items are found by chance, stay where they are, and cost goods, not money.
- **To detail:** the loan's size and rate, and what happens if it isn't repaid (a deadline? debt collectors as encounters?); how many rare items there are and what winning means (repay the loan and collect them all? a score?); how you learn of one (a rumour, or arriving there); which goods each one asks for; whether an item does anything once you have it.

### Combat

- **Decided:** a turn-based duel.
- **To detail:** the duel's state (range bands? hull and shields?); the actions (fire, missile, close in, pull back, flee, surrender or pay); what the enemy does; what you win (bounty, salvage) and lose (cargo, hull, the game); the kinds of opponent.

### Law and smuggling

- **Decided:** safety levels and contraband.
- **To detail:** the levels (say lawless, frontier, policed); how a scan works, and fines or seizure; whether a record or legal status lasts, and what it changes (police attack, ports refuse you).

### Ship and upgrades

- **Decided:** upgrades and 3 or 4 ship classes.
- **To detail:** the classes (cargo, fuel tank, hull, slots, price); the upgrades (cargo holds, fuel tank, lasers, shields, missiles, scanner, escape pod) and their prices; which systems sell what (by tech level?); repair.

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

- **Decided:** a save code typed back in; the galaxy comes from the seed, and stock levels are rebuilt on loading.
- **To detail:** exactly what is saved (seed, day, money, debt, position, cargo, ship and upgrades, legal status, rank, rare items, contract); the alphabet and packing; a check so a mistyped code is caught; about how long it is (aim for 40 characters or fewer).

### Names

- **Decided:** generated from a syllable table.
- **To detail:** the table; names for goods, ship classes and rare items (fixed lists).

## Version 1

The map, the economy, the loan, rare items, the duel, law and contraband, ship upgrades and classes, contracts and rumours, the panels, the save code, generated names.

## Later

Events (shortages, booms); colonies and outposts; ranks with titles; more opponent kinds; a second galaxy.

## Data budget (estimate)

| Data | Size |
|---|---|
| 64 systems × (position 2, type and safety 1, stock of 8 goods 8, last-update day 2) | 832 bytes |
| Visited systems, one bit each | 8 bytes |
| Goods, ships, upgrades, names: fixed tables | under 1 KB |
| The player's state | under 100 bytes |
