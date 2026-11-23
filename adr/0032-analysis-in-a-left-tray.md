# 0032. The Analysis panel is a left tray beside the tools rail, not a dock pane

- **Status:** Proposed
- **Date:** 2026-11-23
- **Supersedes:** 0021 and 0023 in part (the Analysis panel as a single dock panel)
- **Superseded by:** —

## Context

The Analysis panel (adr/0021) docked as a single panel, opened from a `+` menu or by R left
of the spatial view at a third of the window. It is a workbench, not a view: the steps, their
parameters and runs, and the history. In the dock it needed special cases (the `+` menu's
placement, pushed panels kept out of its group), it moved with splits and drags, and a module
(adr/0031) hid it with every other pane while its view was alone.

## Decision

The Analysis panel opens in a left tray (`panels/drawer.ts`) between the tools rail and the
dock, as the controls' tray is at the right edge: page chrome, outside dockview. The tools
rail's analysis button (`monitor-play`) opens and closes it, as `viewer$analysis()` opens it
from R and `remove_panel("analysis")` closes it. One panel at a time (`DRAWERS`, the Analysis
panel today); its right edge drags its width (260 px to half the window, 360 px until
dragged). The panel open and the width are saved with the config (`drawer`,
`drawerWidth`). The panels toggle hides it with the right tray; a module leaves it as it
is, since an analysis is run while its results are looked at.

## Consequences

- The dock holds views and pushed panels only; its special cases for the Analysis panel go.
- `panels()` lists it with group `"drawer"` while open.
- A saved layout with the old Analysis pane loses it on restore (`dropUnavailable()`, as
  for the controls in adr/0027).
- Two rails and both trays open leave the views about 700 px less than the window; each
  tray closes by its own button.
