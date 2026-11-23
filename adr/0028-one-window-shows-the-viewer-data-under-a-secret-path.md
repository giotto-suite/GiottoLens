# 0028. One window shows the viewer; the data is served under a secret sent to it

- **Status:** Proposed
- **Date:** 2026-11-19
- **Supersedes:** —
- **Superseded by:** —

## Context

The viewer URL was the only access check (adr/0006): whoever held it could connect any number
of windows, each able to drive the viewer and to ask R to open any GiottoDisk project (adr/0019), with
the R user's file permissions. The data files (tiles, cell table, metadata, images) were read
with plain HTTP requests under the same URL. The URL is printed in the console, appears in
the process list where `xdg-open` runs, and is easy to paste into a log or a chat.

httpuv serves static paths on its own thread without calling R, so a check cannot be made
per request there; an unguessable path can (adr/0006).

## Decision

One browser window shows the viewer at a time, and R decides which.

- On every connect the page sends `hello` with the key of its last grant. R answers `grant`
  (a data secret and a key) or `wait` (a four-digit code).
- A window is granted the viewer when it sends the key of the window that shows it and
  that window is gone (a reload, a reconnect), or when `viewer$allow()` said the next window
  may: `launch_lens()` does so before it opens the viewer itself in a viewer pane.
- When `launch_lens()` opens the browser with a command (`open`, `xdg-open`, a command in
  `options(browser =)`), the command gets a page in the temp dir, mode 0600, and not the
  viewer URL. The page sends the browser to the URL with a launch key in its fragment
  (`#launch=<key>`). The page takes the key out of the address bar and sends it in `hello`;
  the window that sends it is granted the viewer, once, and the page is removed. The next
  window is not let in.
- The key from a second connection while the window that shows the viewer is still
  connected (a duplicated tab copies the key; a dropped connection R has not seen close):
  R asks that window whether it is there (`probe`). It replies: the newcomer is another
  window and waits with a code. No reply in 2 seconds, or it closes: the newcomer is that
  window again and gets the viewer.
- The window the viewer moved from gets it back with its old key while no window shows the
  viewer, until the new window says `ready`: a move to a window that closes or fails to load
  does not leave the viewer without a window.
- Any other window waits and shows its code. The code is sent to that window alone: R
  prints that a window waits, and tells the window that shows the viewer how many wait
  (`claim_request`), never the code. The viewer moves when the code comes back, through
  `viewer$allow(code)` in the console or typed in the window that shows the viewer (the
  `claim` ask). The window that had the viewer gets `released`. `viewer$allow()` without
  the code of a waiting window warns and changes nothing. A waiting window whose connection
  closes shows no code until it reconnects and R sends it one.
- R listens only to the window that shows the viewer; from any other it reads `hello` alone
  and drops the rest without a warning. Its messages go to that window, from its `ready` on.
  `ready` from a window that never said `hello` is a page from before protocol 8: R warns
  once, naming its protocol when it is one number and `?` otherwise.
- At most 16 other windows are connected, 8 of them waiting with a code. Past 16 the oldest
  one is closed, one that waits with a code last, so the window that shows the viewer can
  always reconnect. Past 8 waiting the one that waited longest is closed, so a new window
  can always wait.
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
  the system's browser at launch instead, from Positron too when R runs on the user's
  machine (not over SSH or in Positron Server, where `browseURL()` is used).
- A window that shows the viewer and does not answer the `probe` in 2 seconds (a frozen
  tab) loses the viewer to a duplicate of it without a code.
- When the viewer moves, the asks the old window was waiting on are rejected there.
- Opened with a command, the viewer URL is not in the process list, and a window opened
  from the URL by hand after such a launch waits with a code.
- Opened in a viewer pane, the first window to connect after `launch_lens()` gets the
  viewer.
- Code running in the window that shows the viewer (a browser extension, an injected
  script) holds the secret and the socket. No server-side rule covers that.
- The page connects before it reads the manifest. `PROTOCOL` is 8.

## Alternatives considered

- **Allowed root folders for opening projects** — limits what a URL holder reaches but not
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
`hello`, `grant`, `admit`, `queue_window`, `tell_waiting`, the `claim` ask, `new_secret`,
`launch_target`, `.open_viewer`, `.write_launch_page`),
`R/protocol.R`;
`inst/viewer-src/core/comms.js` (`acquire`, `onGate`, `takeLaunchKey`), `core/base.ts` (`dataUrl`),
`ui/gate.ts`; `tests/testthat/test-window.R`, `test-server.R`,
`inst/viewer-src/test/core/comms.test.ts`; `SECURITY.md`.
