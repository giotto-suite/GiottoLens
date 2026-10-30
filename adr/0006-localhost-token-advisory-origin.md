# 0006. Serve on localhost under a per-launch token path; the Origin check is advisory

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

The server listened on `0.0.0.0` with no check on WebSocket connections, so the served
directory was readable from the LAN and any page could drive the viewer. A first fix bound
`127.0.0.1` and required a token on the WebSocket only. On a shared machine (an HPC login
node) that still let any other user read the tiles, metadata and cell table over HTTP at
`127.0.0.1:<port>`, even when filesystem permissions keep them out: the server runs as the
viewer's owner. A random port only slows a scan.

httpuv serves static paths on its own thread without calling R, so it cannot check a token
per request; whole-tile serving depends on that thread (adr/0004). The viewer must also work
in IDE viewer panes (Positron, RStudio) and behind proxies (RStudio Server, Workbench, port
forwards), where the browser's Origin is not the server's address.

## Decision

Bind `127.0.0.1` on a random port by default (`host =` to expose). Serve everything (bundle,
session files, tile stores, the WebSocket) under `/lens/<token>/`, with a random 24-character
token per launch from the OS random source (`/dev/urandom`), never R's RNG, which `set.seed()`
and Giotto's default seeds make predictable; any other path is a 404. The unguessable path is the access check, so it
works for the static thread too. An Origin check additionally rejects non-loopback foreign
pages on the WebSocket, and is switched off behind RStudio Server's proxy.

## Consequences

- Without the viewer URL, another local user can find the port but read nothing.
- The viewer URL is a capability: whoever has it can read the data and drive the viewer while
  it runs. It appears in the console (`viewer$url`, `describe()`), so treat it like a password
  in shared logs and transcripts. It is useless after `close()` or a relaunch.
- `host = "0.0.0.0"` exposes the server to the network with only the token protecting it, and
  without TLS the URL travels in clear.
- Proxies other than RStudio Server with a foreign Origin need
  `options(GiottoLens.allowed_origins = ...)`.

## Alternatives considered

- **Token on the WebSocket only** — leaves every file readable by other local users.
- **Token as a query parameter or header checked per request** — httpuv's static thread
  cannot check it; every file request would go through R's main thread (adr/0004).
- **Cookie set on first page load** — same per-request check problem, and cookies are shared
  across ports on `127.0.0.1`.
- **Origin check only** — breaks behind proxies and in IDE panes.

## References

`R/server.R` (`.lens_app`, `.lens_root`, `.ws_allowed`, `.origin_allowed`), `R/viewer.R`
(`.ide`, `check_origin`); `tests/testthat/test-launch.R`; `SECURITY.md`.
