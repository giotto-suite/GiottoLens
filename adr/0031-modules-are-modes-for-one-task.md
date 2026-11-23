# 0031. Modules are modes for one task: their controls in the tray, their view alone

- **Status:** Proposed
- **Date:** 2026-11-22
- **Supersedes:** 0030 in part (one list of controls shown for the tray)
- **Superseded by:** —

## Context

Registration needs its control and the spatial view (split into the image's pane and the
data's while placing points), and none of the rest: charts and the other controls take
room from the two panes being matched. More tasks of this shape are planned (workspaces
such as Compare). Doing each by hand, closing panels and opening them again after, loses
the layout and is not something R can do for an agent.

## Decision

A module is one entry in `MODULES` (`panels/modules.ts`): the controls it offers in the
tray, the one view it shows, whether this launch can use it, and what entering and leaving
do (registration enters landmark mode when it has a registration, and leaves it). One
module is on at a time (store `module`, saved with the config); the tools rail's modules
button enters and leaves one, the tray's rail shows a button to leave it, and R has
`set_module()`. A registration started anywhere (`register_image()`, the register panel)
enters its module.

While a module is on:

- the tray's rail offers that module's controls only, all shown at first; the controls
  shown are kept per module (`trayShown`, keyed by module, `''` without one), so leaving
  puts the tray back as it was and entering again finds the module's as left;
- the data area shows the module's view alone: its pane is maximized (dockview's
  `maximizeGroup()`), which hides the others without rebuilding anything, so the spatial
  view keeps its Deck and tiles. Leaving exits the maximize and gives the pane its width
  back (`focusView()`).

The panels toggle is the same focus on the spatial view, with the tray hidden; it no longer
hides groups one by one.

Rejected: a layout per module swapped with `fromJSON()`. It rebuilds every panel, the
spatial view's Deck and WebGL context included, and its tiles load again on every switch.

## Consequences

- dockview saves a layout without its maximize, so the saved layout is always the one with
  every pane; the module is applied again after a restore. The panels toggle's state is not
  kept across a reload (it was, as hidden groups).
- Making another pane active ends the maximize (dockview's rule), as when R pushes a panel:
  the panes come back while the module stays on.
- Config version 7 keys `trayShown` by module.
- A module needing views that do not exist (two spatial views side by side) would create
  them on entering; the shape above does not change.
