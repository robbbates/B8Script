# Grave prefix (archived)

This folder holds every file that pull request #23 changed, as it stood when
#23 was merged (commit `84b76f3`). The grave-prefix extension codes were then
reverted on main, so main is back to the language as it was before #23.

The folders mirror the repository root: `docs/`, `games/`, `README.md` and
`B8Script-interpreters/` (sources, listings, binaries and tests for every CPU).
The `README.md` beside this file is the repository's root README as #23 left
it, not a description of this folder.
Only the files #23 touched are here, so this folder is a reference copy, not a
complete tree: its tests and build scripts are not meant to run from here.

For a complete, runnable version, use either of these:

- branch `claude/hopeful-gates-3l1une` (the six commits of #23)
- commit `84b76f3` on main (main just after #23 was merged)

The six commits of #23:

1. `811ddf3` The grave becomes a prefix: interpreters, reference and tests
2. `6d0a031` Games, documents and release images for the grave prefix
3. `496e711` Idol converted to the grave's codes, and its tests redone
4. `62193bc` Robots, Dungeon and Wumpus converted; all 54 games now use the grave's codes
5. `5509e8d` Size pass over the grave's code on every CPU
6. `95a7720` Fit the CP/M checked editor in 2048 bytes: no ^V, a three-line report
