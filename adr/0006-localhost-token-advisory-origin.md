# 0006. Serve on localhost with a per-launch token; the Origin check is advisory

- **Status:** Accepted
- **Date:** 2026-10-30
- **Supersedes:** —
- **Superseded by:** —

## Context

The server listened on `0.0.0.0` with no check on WebSocket connections, so the served
directory was readable from the LAN and any page could drive the viewer. The viewer must
still work inside IDE viewer panes (Positron, RStudio) and behind proxies (RStudio Server,
Workbench, port forwards), where the browser's Origin is not the server's address.

## Decision

Bind `127.0.0.1` on a random port by default (`host =` to expose). The WebSocket requires a
per-launch token carried in the viewer URL; that is the real check. An Origin check also
rejects non-loopback foreign pages, and is switched off behind RStudio Server's proxy, where
the token alone decides.

## Consequences

- Viewer URLs carry the token: open `viewer$url`, not `/lens/`.
- Other local users of a shared machine can still read the served files over HTTP, as they
  could read them on disk; the token guards control, not files.
- Proxies other than RStudio Server with a foreign Origin need
  `options(GiottoLens.allowed_origins = ...)`.

## Alternatives considered

- **Origin check only** — breaks behind proxies and in IDE panes.
- **Token on every HTTP request** — no extra protection for files readable on disk, and
  complicates every fetch and the workers.

## References

`R/server.R` (`.ws_allowed`, `.origin_allowed`), `R/viewer.R` (`.ide`, `check_origin`).
