# 0023. The spatial view docks, one Deck per view; page controls move to a tools bar and a selection bar

- **Status:** Proposed
- **Date:** 2026-11-17
- **Supersedes:** 0009 in part (the spatial view stays one view, where it is)
- **Superseded by:** 0027 in part (the selection's actions are a tray control; the tools bar is a fixed rail)

## Context

adr/0009 docked the charts and kept the spatial view out: one view beside the dock, split
from it with Split.js. The aim now is spatial panes that can be split, moved and closed, for
views and spaces and for gmulti samples. A viewer shows one gobject at a time (a joined
object or a gmulti counts as one), so every pane reads the same cell table, masks, rules and
colouring.

The view was a page-level singleton. `state.deckgl` and `state.currentViewState` were used
by about ten modules, and its canvas, HUD, toolbar and overlays were static markup found by
`getElementById`. adr/0016 had already removed that pattern from the controls, because
an id exists once per page.

The view's toolbar also held page-level controls: the project dialog, the panels toggle, R's
connection status, the status line, and the selection's own actions (cross-filter, rules,
invert, clear, select by metadata). The selection is one for the page: rules from every view
and panel combined with OR or AND.

## Decision

The spatial view is a dock panel (`spatial`, one per viewer for now). It can be closed and
opened again from a `+` menu, and a closed one stays closed after a reload (`closedPanels`).
Each view builds its own DOM, keeps references to it, and has its own deck.gl `Deck`. Closing
the view finalizes the Deck and loses its WebGL context, as the scatter panel does. Code
reaches the view through `spatialView()` (`spatial/current.ts`) and does nothing when none
is open.

The page's own controls go to a **tools bar** (`tools`): a dock panel that starts as a
40 px column of icons at the left edge, at most two columns wide, moved by a grip tab and
never closed. Nothing docks into it, as a tab or as a split of it, and it never becomes a tab
of another group. It holds the project dialog, the panels toggle, a `+` to add any panel,
and the actions on the selection (AND or OR, select by metadata, invert, clear). The panels
toggle hides every group except the view's and the bar's.

A **selection bar** along the bottom of the page, outside the dock, shows R's connection,
then the selection (the rules toggle, the count, the rule chips), and the status line. The
rules toggle is its only button and comes before the count, which is wide enough for any
number, so nothing moves when the count changes.

Tools that act in a view (pan, measure, draw, lasso, brush, fit, screenshot) stay in the
view. The view's HUD no longer says "GiottoLens": with several views the name would be
repeated in each. It shows only the cursor and the transcript sampling, and is hidden when
both are empty.

## Consequences

- With no view open, `set_view()`, `zoom_to()`, `screenshot()` and `view_bounds()` stop with
  "no spatial view is open". The camera stays in the config, so a view opened again goes back
  to where it was. A view closed by hand also drops its tiles. One replaced by a layout
  restore keeps them for the view that takes its place.
- Each open view, a background tab included, holds a WebGL context and its own GPU buffers.
  Browsers cap contexts at about 16. Closing a view gives both back.
- `panels()` lists `tools` and `spatial`, and both ids are reserved.
- A saved layout from before this change gets the tools bar and the view placed when it is
  restored.
- dockview splits a removed group's width evenly along its row, and splits a group's width
  with a new neighbour. The tools bar keeps the width it was left at (`holdTools()`). A
  group's lock in dockview stops only the drop and still shows drop targets, so drops on
  the bar's group are refused in `onWillShowOverlay` and `onWillDrop`. Its low layout
  priority is set through dockview's private `_priority`, which relies on dockview-core
  being pinned (4.13.1).
- Split.js is no longer a dependency.
- Not done yet, and needed for several views: a selection source per view
  (`spatial:<id>`), tiles planned over the union of the views' viewports, and in-progress
  drawing state per view (`state.js` still holds one).

## Alternatives considered

- **One Deck drawing several views:** GPU buffers would be uploaded once. But dockview panes
  are separate boxes, so one canvas would have to lie over the whole dock, with each view kept
  on its pane's rectangle. A WebGL context also cannot reach a popout window. deck.gl 9.4's
  multi-canvas mode (`_canvases`) shares one device across canvases. It is experimental, but
  worth checking again before there are several views.
- **Keep the view out of the dock:** it could only be resized against the dock, never
  tabbed, split, moved or closed.
- **Tool modes in the tools bar,** as in an image editor, one tool for every view: a tool
  means different things in panes that are and are not built for it (the scatter has its own
  lasso). Left for later.
- **All of the selection in the tools bar, or all in the bottom bar:** the selection belongs
  to the whole page, and a bar across the bottom shows that. Its buttons, though, moved
  whenever the count before them changed width, so the actions moved to the tools bar.
- **The panels toggle as dockview's maximize:** a maximized group hides the tools bar too,
  and with it the button that undoes it.

## References

`inst/viewer-src/spatial/view.ts`, `spatial/current.ts`, `panels/dock.ts` (`TYPES`,
`placeFixed()`, `toolsGroup()`, `holdTools()`, `togglePanels()`), `panels/tools.ts`,
`ui/selbar.js`; `tests/testthat/test-e2e-layout.R` ("the spatial view docks: …"); adr/0009,
adr/0016.
