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
token. Saves are opened only by a name GiottoLens lists, never by a path from the page.

Who can read or change what GiottoLens writes into a project is decided by the project
folder's permissions, as for your data: GiottoLens has no users and no per-user access
control.

## How it is protected

- **Localhost only.** The server listens on `127.0.0.1` on a random port, so other machines
  cannot reach it. `launch_lens(host = "0.0.0.0")` exposes it to your network; do that only on
  a network you trust, since there is no TLS.
- **An unguessable URL.** Everything is served under `/lens/<token>/`, with a new random
  24-character token each launch, drawn from the operating system's random source (not R's
  random numbers, which `set.seed()` makes predictable). Without the token, the server answers
  nothing but "not found", including to other users on the same machine.
- **Only the stores you launched on.** Files are served from inside those stores; a symbolic
  link inside a store that leads elsewhere is not followed.
- **Origin check.** The WebSocket also rejects pages from foreign sites. Behind RStudio
  Server's proxy this check is off and the token alone protects the connection.

## What you should know

- **Treat `viewer$url` like a password while the viewer runs.** Anyone who has it and can
  reach your machine's localhost (other users on a shared server, for example) can read the
  data being shown and drive the viewer. It is printed in the console and by
  `viewer$describe()`; avoid pasting it into shared logs or chats. It stops working after
  `viewer$close()` or a relaunch.
- **Shared machines (HPC login nodes).** Other users can see that a port is open, but without
  the token they cannot read anything through it.
- **Port forwarding.** Forwarding the port to your laptop (e.g. `ssh -L`) keeps the token
  requirement; anyone with access to your laptop's localhost and the URL could use it.
- **Opening the browser from a terminal on Linux.** `launch_lens()` then runs `xdg-open` with
  the URL, which other users can briefly see in the process list. On a shared machine, use
  `launch_lens(open = FALSE)` and open `viewer$url` yourself, or use RStudio or Positron.
- **Code from `viewer$rules(code = TRUE)`.** Column names and labels in it are quoted and
  escaped, so running it only rebuilds the selection.

## Reporting a problem

Please report security problems privately to the maintainers listed in `DESCRIPTION` rather
than in a public issue. Include what an attacker could do, and the steps to reproduce it.
