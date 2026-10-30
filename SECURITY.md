# Security

GiottoLens runs a small web server inside your R session so a browser can show your data.
This page says what that server exposes and how it is protected.

## What is served

While a viewer runs (`launch_lens()` until `viewer$close()`), its server serves:

- the viewer itself;
- the GiottoDisk tile stores you launched it on, read-only;
- a temporary folder with the cell table and any metadata or panel data you pushed;
- a WebSocket through which the page and R exchange selections and commands.

Nothing is written next to your data, and the server cannot run R code sent from the
browser: it only accepts a fixed set of message types.

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
