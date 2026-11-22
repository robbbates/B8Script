# Trading game: design

Working title, to be named. Nov 22, 2026: every part decided. Numbers marked "to tune" are starting points for play-testing.

A single-player space trading game in B8Script, in the style of Elite and Trade Wars but not a copy of either. You start in debt with a small ship. You trade between generated star systems, smuggle when it pays, fight or flee, take contracts, upgrade your ship, and track down the six parts of an ancient idol, which can only be bartered for. Turn-based throughout.

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
| 3 | Pressure and goal | A loan with interest at the start, plus the six parts of an ancient idol to collect. A part is found by chance, stays in its system, and can only be had by trading certain goods for it, not money |
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
2. **Decide:** buy, sell, take a contract, barter for an idol part, refuel, upgrade, repay the loan.
3. **Pick a destination** on the chart, within fuel range.
4. **Jump:** a day passes. On the way there may be an **encounter** (pirates, police, a trader, nothing), settled by a duel, a bribe, a scan or flight.
5. **Arrive** and go back to 1.

The day count drives everything that changes over time: interest, stock recovery, contract deadlines.

## The parts

Each part says what was decided.

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

**Price.** Each good in each system has a normal stock N: 50 where it is produced, 10 where it is consumed, 30 otherwise. The buy price is base × (90 − stock) ÷ 60, the old formula with N fixed at 30: 1.5 × base when the stock is empty, base at 30, 0.5 × base at 60, the most a system holds. At rest (stock at N) that is ⅔ base where produced, base where neither, 1⅓ base where consumed. The type needs no price factor of its own: the stock does the work. Every base is a multiple of 10, so the program works out base ÷ 10 × (90 − stock) ÷ 6. (changed: base × (3N − stock) ÷ 2N, with the stock recovering to that same N, gives exactly the base price at rest in every system, so producers were never cheap nor consumers dear, and no trade paid.)

**Wobble.** Up to ±10% a day, worked out from the seed, the system, the good and the day, so nothing is stored.

**Selling.** At 7⁄8 of the buy price, so buying and selling in one place loses money.

**Large trades.** Every tonne of one trade goes at the price the stock would give halfway through the trade.

**Stock.** A table of every system's stock (64 × 8 bytes), and each system's last-update day. On arrival the stock recovers by an eighth of its gap to N for each day since, for at most 8 days; only that one system is worked on. Trading moves the stock.

**Money.** Two cells, high × 10,000 + low, printed as the high part then the low part padded to four digits: up to 327 million. Adding and subtracting carry at 10,000. One transaction never passes 32,767: prices stay at most 300 and holds at most 100 tonnes, so every multiply fits one cell.

### Loan and the idol

Decided (Nov 22).

- **The start:** the loan paid for your Courier: you begin owing 5,000, the Courier's price, with 1,000 in cash, enough for a first cargo and fuel.
- **The loan** is kept in one cell, never above 30,000. Each day adds 1% (debt ÷ 100). Pay it off in any amount when docked.
- **Not paying:** once the debt reaches 30,000, debt collectors turn up as encounters (pay, fight or flee) until it is paid. No game over for debt; it reuses the encounter and duel code.
- **Winning:** the loan repaid and all six idol parts held. The score is the number of days taken: fewer is better.
- **Six idol parts,** one bit each, so the collection is one save-code character. They do nothing once held, apart from counting toward the whole idol (perks are under Later).
- **Where:** the seed places them in six systems, mostly frontier and lawless. You learn of one by docking there or from a rumour. An item stays in its system until you trade for it.
- **The price:** goods, not money. The seed sets two different goods for each item, 10 to 30 tonnes of each and at most 40 tonnes in all, sometimes one of them contraband. Hand them over and the item is yours.

### Combat

Decided (Nov 22).

- **An encounter** happens on a jump with a chance set by the destination's safety: policed 10%, frontier 25%, lawless 40% (to tune).
- **Who:** pirates (frontier and lawless; they want your cargo), police (policed systems; they scan you, see Law), debt collectors (anywhere once the debt is at its cap). An enemy's class and levels come from the safety level plus a roll.
- **The duel** tracks hull, shields and a range, far or close.
- **Your actions:** fire lasers (close only), launch a missile, close in, pull back, flee (far only), pay (credits or cargo). One key each.
- **Damage:** a laser hit is level × a roll of 1 to 4, less the target's shield level, at least 1. A missile does 15 and ignores shields. Fleeing works on a 50% roll; on a failure the enemy gets a free shot.
- **The enemy:** closes in, fires lasers when close and a missile when it has one, and flees below a quarter of its hull.
- **Winning:** a bounty for a pirate or a collector, and a chance of salvage (a few tonnes of a random good).
- **Losing:** with an escape pod (2,000, used up), you lose the ship and cargo and wake at home in a new Courier, whose 5,000 is added to the loan (up to the cap). Debt and idol parts are kept. Without one, the game is over.

### Law and smuggling

Decided (Nov 22).

- **Safety levels:** policed, frontier, lawless, by distance from home (see the map).
- **Contraband prices** use the economy's formula, with the normal stock set by safety instead of type: 50 in lawless systems (cheap), 30 in frontier ones, 10 in policed ones (dear). Buy at about two thirds of the base price at the edges and sell for about four thirds of it near the centre. No black market of its own. (changed: about half and one and a half, with the price formula.)
- **A police encounter is a scan.** Contraband in the ordinary hold is always found. You then choose: **submit** (it is confiscated, and you are fined its base price per tonne) or **resist** (a duel with the police; win it and you are wanted).
- **Wanted:** a counter of days. While it runs, police attack on sight in policed systems, and the police encounter chance there rises from 10% to 15% (to tune). It clears after 20 days without trouble.
- **A hidden hold** (3,000, any class) carries up to 10 tonnes that a scan misses 3 times in 4.

### Ship and upgrades

Decided (Nov 22).

**Stats:** cargo, fuel tank, hull, laser level, shield level, missiles, an escape pod (see Combat), a hidden hold (see Law).

**Classes.** Every class can add up to 3 cargo pods (+10 tonnes each) and 2 tank upgrades (+2 each), so cargo never passes 100 and the tank never passes 14 (the economy and the map rely on both).

| Class | Cargo | Tank | Hull | Laser max | Shield max | Price |
|---|---|---|---|---|---|---|
| Courier (start) | 20 | 7 | 30 | 2 | 2 | 5,000 |
| Freighter | 50 | 8 | 50 | 2 | 3 | 9,000 |
| Raider | 30 | 10 | 60 | 4 | 4 | 12,000 |
| Clipper | 70 | 10 | 80 | 4 | 4 | 30,000 |

**Upgrades:** laser and shield levels up to the class's limit, at 1,000, 2,500, 5,000 and 9,000 a level; missiles at 500 each, at most 4; cargo pods at 1,500 each; tank upgrades at 2,000 each.

**Where:** fuel and repairs everywhere; upgrades at industrial and high-tech systems; ships only at high-tech.

**Buying a ship:** the old one is traded in at half its price. Upgrades carry over, cut to the new class's limits; if the cargo doesn't fit, the trade is refused.

**Running costs:** fuel 20 a unit, repairs 50 a hull point, the same everywhere.

### Contracts and rumours

Decided (Nov 22).

- **Two kinds of contract.** **Carry:** sealed cargo or passengers (the same rules, other words), taking hold space, to system S by day D. **Bounty:** a tougher pirate waits at system S; winning that duel pays.
- **One contract at a time,** so the save code holds one.
- **Offers:** each system offers 0 to 2 when you dock, generated from the seed, the system and the day; nothing is stored until you accept one.
- **Pay:** 100 per unit of fuel distance plus 20 a tonne (to tune). The deadline is the trip's length plus some slack. Late: half pay. Cargo lost in a fight: the contract ends unpaid. No deposit.
- **Selling sealed cargo** is allowed: you become wanted, and the cargo's base value is added to your loan (the shipper's insurer bills you through your lender), so theft only pays where the price is well above base. Passengers can't be sold; leaving them anywhere else fails the contract.
- **Rumours:** one free rumour each time you dock, always true, of three kinds: where a good is scarce (a real consumer), where pirates are thick, or where an idol part lies (only ones not yet found).

### Screen

Decided (Nov 22).

- **Layout,** 80 × 24, drawn with single-line borders (`+ - |`) once at the start: row 1 status; rows 3 to 18 the main area (56 wide) beside the side panel (21 wide: cargo, contract); rows 20 to 22 messages; row 23 the command line. Only what changes is redrawn.
- **Main-area views:** Chart, Market, Shipyard (upgrades and ships), Duel, Help. Contract offers and the rumour appear in the messages on docking; an accepted contract shows in the side panel.
- **Keys.** Docked: `c` chart, `m` market, `y` shipyard, `k` take a contract, `l` pay the loan, `f` refuel, `r` repair, `t` trade for an idol part, `v` show the save code, `?` help, `q` quit. Market and shipyard: `w` and `s` move the row (the terminal's cursor sits on it), `b` buy, `x` sell, then a quantity. Chart: two keys step through the systems in range, Return jumps. Duel: `l` lasers, `m` missile, `c` close, `p` pull back, `f` flee, `$` pay. Each view lists its keys on its last line.
- **Quantities** are typed (read with `-4?`); Return alone means as many as possible: all you can afford and fit, or all you hold.
- **Messages:** the newest on row 22, older ones moving up, kept in a 3 × 78-byte buffer and redrawn on each new message.

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
- **What is saved,** 220 bits, so 37 characters, plus the salt and check characters: 39 in all.

| Value | Range | Bits |
|---|---|---|
| Format version (old codes are refused after a change) | 0–15 | 4 |
| Seed | any | 16 |
| Day | 0–1023 | 10 |
| Money | up to 9,999,999 (high part 0–999, low part 0–9,999) | 24 |
| Debt | 0–30,000 | 15 |
| Position | system 0–63 | 6 |
| Cargo | 8 goods × 0–100 | 56 |
| Ship: class, laser, shield, missiles, pods, tank upgrades, hull, fuel, escape pod, hidden hold | | 28 |
| Wanted days | 0–20 | 5 |
| Idol parts held, and idol parts known | 6 + 6 | 12 |
| Contract: kind, destination, good, tonnes, deadline, pay, passenger flag | | 44 |

- **Not saved:** the chart's visited marks (after loading, every system looks unvisited again), the stock levels (rebuilt), and which contraband is in the hidden hold (contraband always fills the hidden hold first, so it follows from the cargo).
- **The game ends at day 999,** which also bounds the score and fits the day in 10 bits.

### Names

Decided (Nov 22).

- **Systems:** generated from a table of 32 two-letter syllables (consonant–vowel pairs and a few endings); a name is 2 or 3 syllables chosen from the seed and the system's number, as Elite did. 64 names, different every seed, from a 64-byte table.
- **Goods and ship classes:** as in their tables above.
- **The idol** is named from the same syllables (*the Idol of Xeroon*, say), so every galaxy has its own. The parts: the Head, the Eye, the Heart, the Left Hand, the Right Hand and the Base (one word each in tables: Head, Eye, Heart, LHand, RHand, Base). Holding all six makes the idol whole; with the loan repaid, that wins.

## Version 1

The map, the economy, the loan, idol parts, the duel, law and contraband, ship upgrades and classes, contracts and rumours, the panels, the save code, generated names.

## Later

Events (shortages, booms); colonies and outposts; perks for the idol parts; ranks with titles; more opponent kinds; a second galaxy.

## Data budget (estimate)

| Data | Size |
|---|---|
| 64 systems × (position 2, type and safety 1, stock of 8 goods 8, last-update day 2) | 832 bytes |
| Visited systems, one bit each | 8 bytes |
| Goods, ships, upgrades, names: fixed tables | under 1 KB |
| The player's state | under 100 bytes |
