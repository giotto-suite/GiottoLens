# 0016. The side panel's controls dock as self-contained panels

- **Status:** Proposed
- **Date:** 2026-11-07
- **Supersedes:** 0009 in part (only chart panels dock)
- **Superseded by:** —

## Context

The side panel was a fixed 260 px column beside the dock, its sections (transcripts,
annotations, cells, images, register, opacity) written as static HTML in `index.html` and
wired by global `getElementById` lookups from several modules, some once at start-up and some
on every update. Its sections could only collapse. The dock (adr/0009) already gave the charts
tabs, splits, closing, the `+` menu and a layout saved through R.

Moving the sections into the dock as they were would have kept the global lookups. A closed
dock panel's content leaves the document, so a lookup on update would find nothing and throw;
an id exists once per page, which rules out a control per view (several spatial views, the
spaces work) and a control in a popout window, where `document` is the other window's.

## Decision

Each section becomes a built-in panel with the charts' contract, `create(body, ctx) →
{ destroy }`: it builds its own DOM, keeps references to it, follows the store through
subscriptions it drops in `destroy()`, and is styled by class. Built-in panels are listed in
one table (`TYPES` in `panels/dock.ts`): a chart needs metadata and can be added more than
once; a control is one per viewer, its id is its kind, and `available()` says whether the
launch has what it shows. The default layout puts the controls in a 260 px column at the
dock's right edge, grouped by subject into slots of at most two tabs (cells and transcripts;
images and register; annotations; layers), since a third tab does not fit the column's tab
bar. A control carries no element ids; tests find it by `[data-panel=<id>]` and class. A
control closed by hand is recorded in the saved config (`closedPanels`) so a reload leaves
it closed, and a saved layout without a control (from before it existed) gets it placed. A
chart pushed from R without `ref` goes next to the charts, never among the controls.

## Consequences

- Controls tab, split, close and restore like charts; `push_panel(ref = "cells")` works.
- The stats toggle hides every panel, controls included.
- A second instance of a control (per view) needs a per-instance id in `TYPES`, not changes
  to the control's module.
- dockview mounts a tab's content the first time it is shown; a control must not rely on its
  DOM existing before then (it reads the store when created).
- `.lens_builtin_panels` in R and `TYPES` in the browser list the same kinds; keep them in step.
- `panels()` lists panels in layout order rather than creation order, so a reload keeps it.

## Alternatives considered

- **Keep the side panel, dock only charts:** the controls could not sit beside a chart, be
  closed, or be placed from R, and two layout systems would be saved differently.
- **Move the sections into the dock unchanged (static HTML, global ids):** smallest change,
  but a closed panel breaks per-update lookups, and controls stay one per page.
- **A separate dockview instance for controls:** two layouts to save and restore, and no
  dragging between them.

## References

`inst/viewer-src/panels/dock.ts`, `panels/cells.ts`, `panels/layers.ts`; adr/0009;
`tests/testthat/test-e2e.R` ("the controls dock in their own column").
