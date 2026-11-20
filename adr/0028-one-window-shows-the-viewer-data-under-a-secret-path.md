# 0028. One window shows the viewer; the data is served under a secret sent to it

- **Status:** Proposed
- **Date:** 2026-11-19
- **Supersedes:** —
- **Superseded by:** —

## Context

The viewer URL was the only access check (adr/0006): whoever held it could connect any number
of windows, each able to drive the viewer and to ask R to open any GiottoDisk project, read
any dataset folder and create a project in any writable folder (adr/0019, adr/0027), with the
R user's file permissions. The data files (tiles, cell table, metadata, images) were read
with plain HTTP requests under the same URL. The URL is printed in the console, appears in
the process list where `xdg-open` runs, and is easy to paste into a log or a chat.

httpuv serves static paths on its own thread without calling R, so a check cannot be made
per request there; an unguessable path can (adr/0006).

## Decision

One browser window shows the viewer at a time, and R decides which.

- On every connect the page sends `hello` with the key of its last grant. R answers `grant`
  (a data secret and a key) or `wait` (a four-digit code).
- A window is granted the viewer when it sends the key of the window that shows it (a
  reload, a reconnect), or when `viewer$allow()` said the next window may: `launch_lens()`
  does so before it opens the viewer itself.
- Any other window waits and shows its code. The code is sent to that window alone: R
  prints that a window waits, and tells the window that shows the viewer how many wait
  (`claim_request`), never the code. The viewer moves when the code comes back, through
  `viewer$allow(code)` in the console or typed in the window that shows the viewer (the
  `claim` ask). The window that had the viewer gets `released`. `viewer$allow()` without
  the code of a waiting window warns and changes nothing.
- R listens only to the window that shows the viewer; from any other it reads `hello` alone.
  Its messages go to that window, from its `ready` on.
- The data is served under `/lens/<token>/d/<secret>/`. The secret is sent only in `grant`,
  never printed and never part of the URL the user opens. A grant to a window that did not
  hold the key sets a new secret and a new key, so the window released can no longer read.

## Consequences

- The viewer URL alone gives the bundle (code) and a socket on which only `hello` is read:
  no data, no file access, no driving the viewer.
- A second view of the same viewer (two monitors, a pane and a tab at once) is gone. A
  window that was moved away from says so and can ask for the viewer back.
- `launch_lens(open = FALSE)` needs `viewer$allow()` before the URL is opened, in scripts,
  tests and agent use.
- A viewer pane popped out to a browser tab is a new window: its code typed in the pane,
  or `viewer$allow(code)`, moves the viewer. `options(GiottoLens.viewer = "browser")` opens
  the system's browser at launch instead, from Positron too.
- The first window to connect after `launch_lens()` opens the viewer gets it. On a shared
  machine another user who reads the URL from the process list can race it; the R user then
  sees a waiting window instead of the viewer.
- Code running in the window that shows the viewer (a browser extension, an injected
  script) holds the secret and the socket. No server-side rule covers that.
- The page connects before it reads the manifest. `PROTOCOL` is 8.

## Alternatives considered

- **Allowed root folders for open and import** — limits what a URL holder reaches but not
  who; depends on the roots being set well, and leaves the data shown readable.
- **Approval per window with several windows live** — keeps two views; two levels of access
  to explain and test, and the data still under the URL.
- **Newest window takes over** — no step for a pop-out, but a URL holder takes the viewer.
- **First window keeps the viewer, no key** — a reload or a dropped connection frees it for
  whoever connects next.
- **A cookie or header checked per request** — httpuv's static thread cannot check it
  (adr/0006, adr/0004).

## References

`R/server.R` (`.data_root`, `.data_paths`, `.lens_app`), `R/viewer.R` (`allow()`, private
`hello`, `grant`, `admit`, `queue_window`, `tell_waiting`, the `claim` ask, `new_secret`),
`R/protocol.R`;
`inst/viewer-src/core/comms.js` (`acquire`, `onGate`), `core/base.ts` (`dataUrl`),
`ui/gate.ts`; `tests/testthat/test-window.R`, `test-server.R`,
`inst/viewer-src/test/gate.test.ts`; `SECURITY.md`.
