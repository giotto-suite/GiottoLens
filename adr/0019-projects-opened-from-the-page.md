# 0019. Projects are opened from the page, and R does the opening

- **Status:** Proposed
- **Date:** 2026-11-12
- **Supersedes:** —
- **Superseded by:** —

## Context

Since adr/0018 the viewer shows a snapshot of a GiottoDisk project, and it can start
without an object (adr/0017). An empty viewer only said to call `set_object()` from R. To
start from the browser, the page has to find a project, list its snapshots and open one,
and switching from the page has to protect Lens work as `set_object()` does. The page so far
only told R what happened (selections, config) and answered R's requests; nothing went the
other way.

## Decision

**R does all of it; the page asks.** A new message, `ask` (`{op, ...}`, with an id), is
answered to that page only with `answer` (`{id, data | error, code}`). The page has four
requests: `projects` (the open project, the recent ones, whether a folder dialog exists),
`browse` (the folder dialog), `snapshots` (a project's live snapshots) and `open` (show a
snapshot). The page reads no files and keeps no list of its own. Protocol 6.

**Only existing projects.** A path is opened only if it holds `giottodir.json`; opening,
from the page or with `viewer$open_project()`, never creates a project. Listing a project's
snapshots doesn't change what the viewer shows; only `open` does.

**`open_project(path)` shows the project's start page** and drops the object shown;
`open_project(path, name)` and `checkout(name)` show a snapshot. `launch_lens(project =)`
without an object starts on that project's start page. All of them refuse to drop Lens work
without `discard = TRUE`. The page's `open` gets the same refusal as an answer with code
`work`, asks the user in a dialog (discard and open, or cancel), and sends `open` again with
`discard`. The rule is enforced in one place, R.

**A snapshot is shown as it was saved.** `checkout()` loads it with `loadGiotto()` and shows
it under its own tag, without the manifest comparison or a new save. A snapshot saved
without `manifest.json` would otherwise get a new `lens_` save each time it is opened.
Spatial unit and feature type: the page offers those the snapshot's `manifest.json` lists.
Left out, they are the viewer's current ones if the snapshot has them, else the object's
defaults (`set_default_spat_unit()`, `set_default_feat_type()`), else `"cell"` and
`"rna"`, else its first.

**The list hides automatic saves.** Snapshots the viewer saved on its own and nobody kept
(`creator = "GiottoLens"`, `keep = FALSE`) are behind a "show automatic saves" toggle,
except the one shown. The list is flat, newest first; the snapshot tree comes later.

**Recent projects** are one list per user, newest first, up to 10, in
`tools::R_user_dir("GiottoLens", "data")` (or `options(GiottoLens.recent_projects =)`). A
project goes on the list whenever the viewer opens it, a hand-over included.

**The folder dialog is the IDE's**, through `rstudioapi::selectDirectory()`: RStudio has it.
Positron (2026.10) doesn't, nor does a plain R console, so there the page offers recent
projects and a path box only. The button appears only when R is interactive and the
function exists, so it appears in Positron once Positron adds it.

## Consequences

- From the page, the browser can make R list and open any GiottoDisk project the R user can
  read. The token still guards this (SECURITY.md), but it is more than reading the stores
  the viewer was launched on.
- Opening runs on R's thread inside the socket handler: the page and the console wait for
  `loadGiotto()`. Loading a large project takes seconds.
- Recent projects are written to the user's data directory.
- Old snapshots (no `manifest.json`) open with the default keys, with no picker.

## Alternatives considered

- **A file browser in the page:** R would list directories to the browser, a larger surface
  than "is this a project", and it duplicates the OS dialog badly.
- **Folder dialogs outside the IDE** (osascript, PowerShell, zenity): rejected, IDE only.
- **`open_project(path)` opening the latest snapshot:** the start page lets the user pick,
  and loading a project can be slow.
- **The page checks for work itself:** the refusal would be in two places; R already knows
  the work (`lens_work()`).
- **Compare manifests on checkout too:** a snapshot just loaded is the snapshot; the check
  costs seconds on large objects and saves a copy of old snapshots.

## References

`R/projects.R`, `R/viewer.R` (`open_project`, `checkout`, `open_snapshot`, `check_work`,
`ask`), `R/protocol.R`, `inst/viewer-src/ui/start.ts`, `inst/viewer-src/core/comms.js`
(`askR`); `tests/testthat/test-projects.R`, `tests/testthat/test-e2e.R`.
