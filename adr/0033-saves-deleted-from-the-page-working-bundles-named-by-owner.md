# 0033. Saves are deleted from the page; a working bundle names its user and beats

- **Status:** Proposed
- **Date:** 2026-11-23
- **Supersedes:** 0026 in part (a working bundle on another machine)
- **Superseded by:** —

## Context

adr/0026 deletes a save or the work a viewer that ended left only from R
(`delete_save()`). The page makes both, with the tools bar's save button and by closing, and
lists both on the start page, so someone who never uses R could not remove either: work
left by viewers piled up, and a save whose snapshot was deleted stayed listed with nothing
to do. The page could already delete indirectly: saving over a name replaces that save, and
opening work a viewer left removes it.

A viewer's work is the work of a running viewer when `bundle.json`'s host is this machine
and its process runs. On another machine that could not be told (`live` was `NA`), and
`open_save()` and `delete_save()` refused only `TRUE`: on a project on a shared file system,
another machine could open, and so remove, the work of a viewer still running.

The start page listed the work every ended viewer left, whoever's, with nothing to tell
whose it was.

## Decision

**The start page deletes.** A save row has Delete and a row of work not saved has Discard,
each confirmed first, in any project the page lists; ticked rows are deleted together. They
ask R (`delete_save`, with path and names), which deletes as `delete_save()` does, all
names checked before any is deleted: only a name `.lens_saves()` lists, never
the work of a viewer still running or the viewer's own. A save's snapshot stays kept.

Only the window that shows the viewer is listened to (adr/0028), so the button gives no one
a power the page did not have: a window with the URL but no code cannot ask.

**A link in `lens/` is never a bundle.** `.lens_saves()` skips links, so a link named like a
bundle is neither opened, deleted nor overwritten, whatever it leads to. Bundle files were
already read only if not links (`.bundle_file()`); the folder now is too.

**A running viewer beats.** `bundle.json` is rewritten at least every 30 s
(`.heartbeat_s`), from the autosave loop. A working bundle from another machine belongs to a
running viewer when `bundle.json` changed less than four heartbeats ago; on this machine the
process check stays. `live` is now `TRUE` or `FALSE`, and the old `NA` case is refused as
`TRUE` was. `updated` stays when the work was last written: a beat rewrites the time of the
file, not the field.

**A working bundle names its user.** `bundle.json` gets `user` (`Sys.info()[["user"]]`),
kept in a save. The start page says whose work another user's viewer left, and lists only
work not known to be someone else's unless asked (`show work left by others`). It is a label
for browsing, not access control (adr/0026): anyone who can write the project can delete
there.

## Consequences

- One click and a confirm delete work for good; there is no bin.
- A viewer whose machine stops beating, or whose clock is more than about a minute and a
  half from the file server's, is taken as ended: its work can be opened elsewhere.
  A viewer of an earlier version on another machine never beats and counts as ended within
  two minutes.
- Bundles written before `user` existed count as this user's.
- A beat writes `bundle.json` in the project twice a minute per running viewer.

## Alternatives considered

- **Working bundles in a per-user folder (`tools::R_user_dir()`):** rejected in adr/0026;
  the owner label lets the page hide others' work without moving it.
- **A refusal for any working bundle from another machine:** work left on an HPC node that
  never comes back could then not be opened or deleted anywhere.
- **The heartbeat in the `updated` field:** the start page shows it as when the work
  changed.
- **Releasing the snapshot's `keep` with the last save on it:** the user may have set it;
  left open.

## References

adr/0026, adr/0028; `.session_live()`, `.lens_saves()` in `R/bundle.R`; `heartbeat()`,
`delete_save_in()` in `R/viewer.R`; `remove()` in `inst/viewer-src/ui/start.ts`.
