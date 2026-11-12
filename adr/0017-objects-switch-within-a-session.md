# 0017. A viewer switches objects within its session, each from a clean slate

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

A load starts the new object from a clean slate: the settings, rules, annotations,
registration, pushed panels, metadata and column types of the previous object are dropped,
and its metadata and panel files deleted. Nothing is kept in memory for when the object is
shown again. Work that cannot be redone by running code again (rules, annotations, pushed
panels, a registration in progress) is not dropped by accident: with any of it,
`set_object()` stops before changing anything and names it, unless called with
`discard = TRUE`, as `snapshotSave()` refuses to overwrite without `overwrite = TRUE`. The
same argument is how a switch made in the page (to come) goes through, after the page's
own confirmation, so R enforces one rule wherever the switch comes from. Keeping Lens work is the job of an explicit save
of the viewer's work (to come), which refers to a snapshot of the object and holds what
only exists in the viewer; what can be derived from the snapshot is derived again rather
than stored.

Files whose name stays the same across loads are never served from the browser's cache:
the manifest is fetched with `cache: 'no-store'`, and the cell table is named per load.
httpuv's `Last-Modified` has one-second resolution, so a reload within the same second
could otherwise get the previous object's files.

A viewer can start without an object (`launch_lens()`): the page says how to load one, and
methods that need one stop with that message.

## Consequences

- `set_object()` returns before tabs have reloaded; calls that need the page wait for a tab
  to connect, as after `launch_lens()`.
- Switching back to an object means pushing its metadata and panels again, and redoing
  selections, unless the work was saved.
- Until a save exists, any rules or annotations count as work. Once one does, only work
  changed since the last save should.
- `close()` does not refuse yet: it is the explicit end of the viewer, and cleanup (package
  unload, a failed launch, tests) must close without asking. Once a save exists,
  `close(discard = FALSE)` should refuse unsaved work, and so should `launch_lens(port =)`
  replacing a viewer on that port; internal teardown goes through a private close that
  never refuses.
- Selected genes (by name) and the camera are part of the config, so a reload of the same
  object keeps them, and a save can hold them.
- Layers launched without a giotto object are deprecated.

## Alternatives considered

- **A new viewer per object:** a new URL each time.
- **Swap the object in the page without a reload:** every module would need to drop its
  data and handlers; a reload resets all of it.
- **Keep each object's state in memory, by `objUID()`, and restore it on switching back:**
  a second place for Lens work besides the save, lost on `close()` and invisible. Getting
  the key right (spatial unit, feature type, which cells) and keeping its files out of
  pruning was most of the code, for the convenience of switching back without saving.
  Tried and removed before merging.
- **Keep only the settings per object:** the same second place, for less.
- **Warn and drop:** the warning comes after the work is gone.
- **Ask in the page, or at the console (`askYesNo()`):** R would wait on the browser for a
  command typed at the console, an agent cannot answer, and the suite has no console
  prompts; both still need a default when nobody can answer.

## References

`R/viewer.R` (`set_object`, `load`, `clear_object`, `set_routes`, `reload_tabs`),
`R/server.R` (`.lens_app`, `.files_paths`), `R/export.R` (`.export_empty`),
`inst/viewer-src/main.js`, `core/comms.js` (`setHello`);
`tests/testthat/test-launch.R`, `tests/testthat/test-e2e.R`.
