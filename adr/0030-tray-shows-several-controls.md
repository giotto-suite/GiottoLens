# 0030. The tray shows several controls at once, stacked, and its dividers drag

- **Status:** Proposed
- **Date:** 2026-11-22
- **Supersedes:** 0027 in part (one control at a time, `trayActive`; the fixed width)
- **Superseded by:** —

## Context

adr/0027 gave the tray one control at a time, the last picked, with the whole height to
itself. In use the controls are wanted side by side: the layers panel while selecting, the
selection panel while drawing annotations. Picking one hid the other, so working across
two meant going back and forth on the rail.

## Decision

Each rail button shows or hides its control. The controls shown (`trayShown`, saved
through R) stack in the tray in rail order and share its height, each scrolling in its own
body. A button on a folded or hidden tray opens it with that control shown. With every
control hidden the tray stays open, empty but for a note; only its arrow folds it. Before
any is picked (`trayShown` null), the first control this launch has is shown, as before.

The dividers drag, as the dock's do: the one between the rail and the column sets the column's width (200 px to
60% of the window; `trayWidth`, 260 px until dragged), and the divider between two
controls shown moves height between them (60 px each at least; `traySizes`, their shares).
Both are saved with the config once a drag ends. Every divider, the dock's too, lights in
the accent colour as soon as the pointer is on it.

`showControl()` (R asking to bring one forward, the metadata note's Data panel link) adds
the control to those shown rather than replacing them; `remove_panel()` of a control hides
that one. `panels()` lists every control shown.

## Consequences

- Controls shown share the tray's height evenly until a divider is dragged; their shares
  are kept by control, so one hidden and shown again takes its old share.
- Config version 6 turns a saved `trayActive` into a list of one.
- The rest of adr/0027 stands: controls never docked, the fold arrow.
