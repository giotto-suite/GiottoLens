# 0017. A viewer switches objects within its session; state is kept per object

- **Status:** Proposed
- **Date:** 2026-11-11
- **Supersedes:** —
- **Superseded by:** —

## Context

A viewer was built around one object: the constructor wrote the manifest, mounted that
object's stores and recorded its cell order, and the page read the manifest once. Showing
another object meant a new viewer with a new URL, and what the viewer held for the first
object (its settings, rules, pushed panels, metadata) was lost. The hand-over between R and
the viewer through snapshots, a start page for opening a project, and a saved session
(#21) all need one session to show one object after another.

## Decision

Loading is a step of its own (`private$load()`), used by `launch_lens()` and
`viewer$set_object()`. The server, its URL and token stay for the whole session. A load
writes the object's manifest and cell table, swaps the stores and images the server answers
for (`routes`, read per request; httpuv's static paths for `files/` are removed and added on
the running server), and tells open tabs to `reload`. The page then starts from the new
manifest: there is no teardown code in the browser to keep correct.

The manifest carries the load's number, and a tab says which load it has in `ready`. R
ignores messages about the object (`.lens_object_types`: selection, config, annotations,
panels, registration, column types) from a tab whose load is not current, and tells a tab
that connects with an older load to reload. Otherwise a tab still showing the previous
object, or its config sent on `pagehide`, would overwrite the new object's state.

What the viewer holds for an object is kept by its `objUID()` when another is shown, and
taken back when that object is shown again. The settings, annotations and registration
hold names and coordinates, so they come back whatever the cells. Rules, metadata and
pushed panels index cells by position, so they come back only when the cells are the same
(`.cells_fingerprint()`: the count and an MD5 of the IDs in order). Files the session keeps
for objects not shown (metadata columns, panel data) are not pruned while they are kept.

Files whose name stays the same across loads are never served from the browser's cache:
the manifest is fetched with `cache: 'no-store'`, and the cell table is named per load.
httpuv's `Last-Modified` has one-second resolution, so a reload within the same second
could otherwise get the previous object's files.

A viewer can start without an object (`launch_lens()`): the page says how to load one, and
methods that need one stop with that message.

## Consequences

- `set_object()` returns before tabs have reloaded; calls that need the page wait for a tab
  to connect, as after `launch_lens()`.
- Kept state is in memory; it is what a saved session (#21) would write to a file.
- Layers launched without a giotto object share one key; such launches are deprecated.
- Selected genes and the camera are part of the config, by name and in data coordinates,
  so they come back with an object and after a reload.

## Alternatives considered

- **A new viewer per object:** a new URL each time, and nothing carried over.
- **Swap the object in the page without a reload:** every module would need to drop its
  data and handlers; a reload resets all of it.
- **Key kept state by a hash of the object's manifest:** changes with every edit, so state
  would never come back after a step; the uid stays with the object.
- **Keep only the page's config per object:** rules, panels and metadata would be lost on
  every switch.

## References

`R/viewer.R` (`set_object`, `load`, `stash`, `unstash`, `set_routes`, `reload_tabs`),
`R/server.R` (`.lens_app`, `.files_paths`), `R/export.R` (`.export_empty`,
`.cells_fingerprint`), `inst/viewer-src/main.js`, `core/comms.js` (`setHello`);
`tests/testthat/test-launch.R`, `tests/testthat/test-e2e.R`.
