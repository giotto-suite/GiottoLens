# 0027. The controls are in a fixed-width tray beside the dock; the dock holds views

- **Status:** Proposed
- **Date:** 2026-11-19
- **Supersedes:** 0016 in part (controls no longer dock), 0023 in part (selection actions)
- **Superseded by:** —

## Context

adr/0016 moved the side panel's sections into the dock as self-contained panels, placed by
default in a 260 px column at the dock's right edge, grouped by subject into slots of at most
two tabs, since a third did not fit the column's tab bar. By then there were eight controls
(cells, transcripts, data, regions, images, register, annotations, layers), so the column
was five slots stacked, each sized by hand (`sizeControls()`), and each new control was one
more slot and one more placement rule run against whatever layout the user had dragged into.
The controls are written for that width; the views (the spatial view, charts, the table,
pushed panels) are what gain from tabs, splits and dragging.

The `+` menus listed every built-in kind, about fifteen, mixing two actions: a chart was
added, a control already open was brought forward.

## Decision

The controls leave the dock for a tray: a column of fixed width (260 px) at the page's
right edge, outside dockview, with a rail of icons at the edge. The rail lists every control
the launch has (`CONTROLS` in `panels/tray.ts`), and the tray shows one at a time, the last
picked (`trayActive`, saved through R), with the whole height to itself. A click on the one
shown folds the tray to its rail. The dock holds views only, and its `+` menus offer views
only.

The actions on the selection (AND or OR, invert, clear), which adr/0023 put in the tools
bar, become a control too (`selection`): the tools bar keeps the page's own actions
(project, save, panels, `+`, jobs, preferences). The same panel lists the selection's rules
as cards, which leave the selection bar, and the saved selections (adr/0029; the Regions
panel's differential expression form is left to a job interface, with
`compare_selections()` in R meanwhile). Select by metadata moves to the cell table's filter button: a `meta` rule kept
apart from the table's picked rows, so it narrows the rows the picks are made from.

How each layer is drawn is one control (`layers`): a collapsible section per layer (cells,
transcripts, images, annotations) whose header is the layer's visibility and opacity and
whose body is that layer's settings, the former cells, transcripts and images controls. A
collapsed section keeps its body. The arrow at the top of the rail folds the tray to its
rail too (`trayCollapsed`).

The tools bar (adr/0023), a dock panel kept one or two icons wide by dockview's private
layout priority and drop refusals, becomes a rail at the left edge in the same way: fixed,
outside the dock, 36 px. The page's chrome is then two rails around the dock.

A control keeps adr/0016's contract, `create(body, ctx) → { destroy }`, so only its host
changed. A control is built the first time it is shown and keeps its DOM while another is
shown, as a background dock tab does.

## Consequences

- The two-tab limit, slots and `sizeControls()` are gone; a new control is one entry in
  `CONTROLS` and one icon.
- A control cannot be dragged into the dock, split beside a chart, or placed by
  `push_panel(ref =)`; a `ref` naming one is reported and the panel joins the charts.
- Two controls are never side by side: the layers panel and the selection panel take turns.
  The layers' settings are one control with collapsible sections so that they do not.
- `panels()` lists the control shown after the dock's panels, with group `"tray"`.
  `remove_panel()` of the control shown folds the tray; there is no R call to pick one yet.
- A saved layout with controls in it (before this) loses them on restore (`dropUnavailable()`);
  config version 4 drops controls closed by hand from `closedPanels`.
- The tools bar's panels toggle hides the tray's column with the dock's other groups; the
  rail stays.
- The dock is narrower by the tray's width while it is open, and by the rail (36 px) always.
- Revisit if a control needs more than 260 px, or a second instance per view: either is a
  per-instance id in `CONTROLS`, or an "open in the dock" action for that one control.

## Alternatives considered

- **Keep the controls in the dock, with their column's group locked** (dockview's `locked`
  and width constraints): drops stay out, but the tab bar's limit and the slot placement
  stay, and a user can still drag a control out.
- **A second dockview instance for the controls** (rejected in adr/0016 too): two layouts to
  save, and no dragging between them, which here would be the point but needs none of
  dockview.
- **Several controls shown at once, stacked** (the first version of this): each needed a
  height cap, and the stack grew with every control; once the layers' settings were one
  control, one at a time was enough.

## References

`inst/viewer-src/panels/tray.ts`, `panels/dock.ts`, `core/store.ts` (`trayShown`,
`migrateConfig()`), `index.html` (`#tray`); adr/0016, adr/0023;
`tests/testthat/test-e2e.R` ("the controls are in the tray").
