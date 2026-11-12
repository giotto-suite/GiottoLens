# 0018. The viewer shows a snapshot of the object, in the object's project

- **Status:** Proposed
- **Date:** 2026-11-12
- **Supersedes:** —
- **Superseded by:** —

## Context

The viewer read an object's stores in place and knew nothing of where the object came from.
To save the viewer's work later (#21) against a fixed state of the object, to return the
object it shows, and to open saved states from a project (the start page, to come), the
viewer needs a state of the object it can name: a GiottoDisk snapshot. Objects held only in
memory had a separate path (cells from spatial locations without a store), and a small one
could not be shown at all if its polygons were in memory.

## Decision

A giotto object is shown from a GiottoDisk project, and the project follows the object:
`launch_lens(g)` and `set_object(g)` use `g@source`. An object not in a project needs
`project`, a directory it is written into (`sourceWrite()`), and is saved there with
`keep = TRUE`. `project` with an object already in a project is refused.

What the viewer shows is a snapshot. The object's own snapshots (`@versions$snapshot`) are
tried first, then the latest few others of the same object (`objUID()`); one whose
`manifest.json` shows no change from the object (`manifestDiff()`, with nothing
unfingerprinted) is used as it is. Otherwise the viewer saves a snapshot,
`lens_<date>_<time>` (with `_2`, ... if taken), `creator = "GiottoLens"`, `keep = FALSE`,
and the viewer's session id, which is random and never the access token.

That save never moves the object's data. `snapshotSave()` adopts stores outside the vault by
moving them, which would leave the console's `g` pointing at files that are gone; a save the
user did not ask for must not do that. So when `sourceContains(src, g)` (GiottoDisk) names
stores outside the project, the viewer stops before changing anything and asks for
`g <- saveGiotto(g)`. Changes held in memory are written into the snapshot's object file
and never move anything.

`viewer$gobject()` loads the snapshot shown; `viewer$checkout(name)` shows another snapshot
of the project.

An object written from memory has untiled stores. The viewer reads an untiled geometry
store as one tile, its one parquet file over its extent, which the browser loads whole: up
to 50,000 polygons and 2,000,000 points (`GiottoLens.untiled_max`). Measured in headless
Chrome, 24-vertex polygons cost about 7 KB of JS heap each once drawn, held whatever the
view; points are thinned by zoom when decoded, so their file size is the cost.

## Consequences

- Every giotto object shown has a project and a snapshot; a save of the viewer's work can
  name both.
- Showing an object changed in the console saves a working snapshot; the end-of-session
  cleanup of those is for later, and GiottoDisk's grace period keeps what a deleted one
  reached for a day (GiottoDisk adr/0025).
- Disk results not saved yet must be saved before the object is shown.
- An object in memory with spatial locations only is now written into a project too.
- Large untiled stores are refused; tiling them is a job for later.

## Alternatives considered

- **Read the object in place, as before:** no state to name; the hand-over, the save and
  the start page would have nothing to point to.
- **Always save on hand-over:** a snapshot per call even when nothing changed.
- **Save anyway and ask the user to reassign `g`:** the console's object is broken until
  they do.
- **Copy stores instead of moving them:** needs a copy mode for adoption in GiottoDisk and
  doubles large stores.
- **Tile on write:** a GiottoDisk method was written (GiottoDisk#161) and closed; one tile is
  enough for small objects.

## References

`R/viewer.R` (`.check_project`, `.matching_snapshot`, `.lens_snapshot_name`, `handover`,
`gobject`, `checkout`, `.check_tile_store`), `R/export.R` (`.store_tiles`);
`tests/testthat/test-handover.R`, `tests/testthat/test-e2e.R`; GiottoDisk#162.
