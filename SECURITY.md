# Security

GiottoLens runs a small web server inside your R session so a browser can show your data.
This page says what that server exposes and how it is protected.

## What is served

While a viewer runs (`launch_lens()` until `viewer$close()`), its server serves:

- the viewer itself;
- the GiottoDisk tile stores you launched it on, read-only;
- the files of the images it shows, read-only, each file on its own (not its folder);
- a temporary folder with the cell table;
- the viewer's working bundle in the project (`lens/session-<id>/`), with the metadata and
  panel data the viewer shows; each request is checked so that a link placed in it cannot
  lead outside it;
- a WebSocket through which the page and R exchange selections and commands.

One browser window shows the viewer at a time (adr/0028). The data above is served under a
path that R sends only to that window; the viewer URL alone gives the viewer's code and
nothing else. R listens only to that window.

The server cannot run R code sent from the browser: it only accepts a fixed set of message
types. Through them, the start page can ask R to list the snapshots of a GiottoDisk project
and to show one: any project the R user can read, found by its `giottodir.json`. It cannot list other folders or create projects. The
paths of your recent projects are sent to the page.

## What is written

Besides that temporary folder, GiottoLens writes:

- **into the project of the object shown:** a snapshot of the object when the viewer shows
  an object with changes that no snapshot holds yet (`lens_<date>_<time>`), and, with
  `launch_lens(project =)`, an object that was only in memory; the work done in the viewer,
  as it happens, in `lens/session-<id>/`, which `close()` keeps if it holds work not saved;
  and your saves (`viewer$save()`), in `lens/<name>.<id>/`;
- **in your user data directory:** the list of recent projects.

Of a project, the server serves only the stores and image files it mounted and the viewer's
own working bundle; the project folder itself is never served. Folder names never contain the
token. Saves are opened and deleted only by a name GiottoLens lists, never by a path from the
page; a symbolic link in `lens/` is never taken for a save. The start page can delete a save,
or work a viewer that ended left, in any project it lists, once you confirm; only the window
that shows the viewer can ask. A working bundle records the user, machine and process that
write it.

Who can read or change what GiottoLens writes into a project is decided by the project
folder's permissions, as for your data: GiottoLens has no users and no per-user access
control.

## How it is protected

- **Localhost only.** The server listens on `127.0.0.1` on a random port, so other machines
  cannot reach it. `launch_lens(host = "0.0.0.0")` exposes it to your network; do that only on
  a network you trust, since there is no TLS.
- **An unguessable URL.** Everything is served under `/lens/<token>/`, with a new random
  24-character token each launch, drawn from a cryptographic random source on every platform,
  Windows included (not R's random numbers, which `set.seed()` makes predictable). Without the token, the server answers
  nothing but "not found", including to other users on the same machine.
- **Only the stores you launched on.** Files are served from inside those stores; a symbolic
  link inside a store that leads elsewhere is not followed.
- **Origin check.** The WebSocket also rejects pages from foreign sites. Behind RStudio
  Server's proxy this check is off and the token alone protects the connection.
- **One window, chosen by you.** The window `launch_lens()` opens shows the viewer. Any other
  window that opens the URL shows a four-digit code and waits. The viewer moves to it only
  when you type the code it shows, in the window that shows the viewer or in R with
  `viewer$allow(code)`. The code is shown in the waiting window and nowhere else (not in R,
  not in the other window), so it can only come from a window you can see. The window that had the viewer can no longer read
  the data. A duplicated tab is another window: it shows a code too. After `launch_lens(open = FALSE)`, open the URL and run `viewer$allow(code)`;
  in a script, `viewer$allow()` before the URL is opened lets the next window in.

## What you should know

- **Keep `viewer$url` to yourself while the viewer runs.** Someone who has it and can reach
  your machine's localhost (other users on a shared server, for example) can open a window
  that waits with a code; it reads no data and cannot drive the viewer unless you let it in.
  If a window you did not open is waiting (R prints "a window asks to show the viewer"), you
  cannot let it in by mistake: moving the viewer needs the code only that window shows. The URL is printed in the console and by `viewer$describe()`,
  and stops working after `viewer$close()` or a relaunch.
- **The window `launch_lens()` opens.** When `launch_lens()` opens the browser with a command
  (from a terminal, or with `options(GiottoLens.viewer = "browser")` in Positron), the
  command gets a page in R's temporary folder that only you can read, not the viewer URL.
  That page sends the browser to the viewer with a key that lets one window in, once. A
  window opened from the viewer URL by hand then shows a code: run `viewer$allow(code)`.
  In RStudio's and Positron's viewer panes no command runs: `launch_lens()` lets in the
  first window that connects after it opens the viewer. If your own window shows a code
  instead of the viewer, another window connected first: close the viewer and launch again.
- **Code running in your own window.** A browser extension that can read pages, or a script
  injected into the page, can do what the page can. This is the case for any web page.
- **Shared machines (HPC login nodes).** Other users can see that a port is open, but without
  the token they cannot read anything through it.
- **Port forwarding.** Forwarding the port to your laptop (e.g. `ssh -L`) keeps the token
  requirement; anyone with access to your laptop's localhost and the URL could use it.
- **Opening the browser from a terminal.** `launch_lens()` then runs a command (`xdg-open`,
  `open`), whose arguments other users can briefly see in the process list. They see the
  path of the page above, which they cannot read, and not the viewer URL.
- **Code from `viewer$rules(code = TRUE)`.** Column names and labels in it are quoted and
  escaped, so running it only rebuilds the selection.

## Reporting a problem

Please report security problems privately to the maintainers listed in `DESCRIPTION` rather
than in a public issue. Include what an attacker could do, and the steps to reproduce it.
