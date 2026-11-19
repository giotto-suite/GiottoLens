# 0026. Lens work is saved as a bundle directory in the object's project

- **Status:** Proposed
- **Date:** 2026-11-19
- **Supersedes:** —
- **Superseded by:** —

## Context

Since adr/0017 a viewer drops its work (settings, rules, annotations, pushed panels, a
registration in progress) when it shows another object, and refuses to unless told
`discard = TRUE`; keeping that work was left to "an explicit save of the viewer's work".
Since adr/0018 every object shown is a named snapshot in a GiottoDisk project, so a save can
point to the state of the object it was made on. Issue #21 asked for the save before either
existed, as `viewer$save_state(path)` to any file or folder.

Most of that work lives in R's memory: the config, rules, annotations, registration and
pushed panel specs. The viewer's temp folder (`tempdir()/giottolens/<port>-<rand>/`) holds
what the page reads: the manifest, the cell table, metadata, panel data, the item cache
(adr/0024) and job progress files (adr/0025). R creates it readable by the user only, only R
writes to it, and the server serves all of it.

Two things limit where a save can go. GiottoDisk's `sourcePrune()` keeps only what a live
snapshot reaches, so a save that points into the vault on its own protects nothing. And the
first prototype (GiottoAtlas, 792c102) wrote its viewer files and manifest into an `atlas/`
folder in the data's root and served that whole root without a token; the in-process server
(2996cc3) and the token path (adr/0006) replaced it with mounted stores and a temp folder.
What the server serves must not grow back to the project directory.

## Decision

**A save is a bundle: Lens state plus the snapshot it was made on.** It is a directory
`<project>/lens/<name>.<id>/`, in the project of the object shown, written to a staging
folder in `lens/` and renamed into place, as snapshots are. There is no list of saves: they
are found by reading `lens/`, so two viewers on one project never write the same file. A
save sets `keep = TRUE` on its snapshot (`snapshotMetadata()`).

**What a bundle holds.** What exists only in the viewer:

- `bundle.json`: format version, created, creator, the viewer's session id, the snapshot's
  tag, `objUID()`, spatial unit and feature type, and a cell fingerprint (cell count and a
  hash of the cell IDs). Description and labels are rewritten in place, atomically.
- the config (layers, images, genes by name, colour-by item keys, tool settings, the panel
  layout, the camera), the selection rules, the annotations and a registration in progress,
  as JSON;
- pushed panels, spec as JSON and data as parquet;
- all working metadata as value columns in parquet: pushed metadata, Data-panel pulls and
  ad-hoc results alike. A pull keeps its item key and history as provenance, but its values
  are stored, not read again from the snapshot: the snapshot is pinned and never changes, so
  the values cannot drift from the key, and opening a bundle needs no job. Working metadata
  lives in the bundle, not the vault: no snapshot reaches it, so in the vault it would be
  pruned. Exporting a column into a giotto snapshot is a separate, explicit step.

Not stored: the stores, the cell table and the manifest (derived from the snapshot), the item
cache, job progress, the access token and the URL. Rules that list cells by position apply
only when the fingerprint matches; other rules carry over.

**Work is written as it happens.** Each viewer keeps a working bundle,
`<project>/lens/session-<session id>/`, never served. When an object is shown, R writes its
`bundle.json`; when state in memory changes, R rewrites that file's JSON; when working
metadata or panel data is written to the temp folder, R writes the same parquet into the
working bundle. Each file is replaced atomically (temp file, then rename). A save copies the
working bundle into `lens/<name>.<id>/` within the project; nothing is exported from the temp
folder. The working bundle is what survives a crash, and the one left by a closed viewer is
the project's "last session".

| In the temp folder | In the bundle |
|---|---|
| `manifest.json` | no: derived from the snapshot |
| `cells-<load>.parquet` | no: only the cell fingerprint |
| `metadata/` (pushed, pulls, ad-hoc) | values, plus key and history for pulls |
| `panels/` | data, plus the spec from R's memory |
| `items/` | no: a cache |
| `jobs/<id>.progress` | no: transient |
| (R's memory) config, rules, annotations, registration | JSON |

**The served folder stays private.** The temp folder stays in `tempdir()`. In the project,
anyone who can write to the project could change the files the page reads as R's output, or
place a symbolic link there that the server would follow (only stores are checked for links,
when they are mounted), so a leaked token would expose any file the user can read. What the
page needs from a bundle is written into the temp folder, or sent over the WebSocket.

**A bundle is untrusted input.** Projects are shared, with more than one writer intended, so
a bundle may come from someone else:

- JSON and parquet only, never `rds` or `qs2`: reading one deserializes R objects from a
  file someone else may have written.
- Rules are parsed into rule objects and checked, never evaluated as code. Labels,
  descriptions and panel specs are shown as text in the page, never as HTML.
- A bundle the page asks for is opened only if its name is one R listed for the open
  project; a name is never joined into a path unchecked.
- Nothing secret goes in: not the token, not the URL. The session id is random and is not
  the token (adr/0018).

## Consequences

- Lens writes into the project in three ways: hand-over snapshots (adr/0018), job outputs
  in the vault, and bundles in `lens/`. SECURITY.md says so; what the server serves does not
  change.
- Working metadata and panel data are written twice, once to each folder. They are single
  columns and small tables.
- Anyone who can read the project can read its bundles, working bundles included, as they
  can its data. Lists hide working bundles, as the start page hides automatic snapshots.
- Once saves exist, only work changed since the last save counts as work: `set_object()`
  without `discard`, `close(discard = FALSE)` and `launch_lens(port =)` over a running viewer
  refuse only that (#21, adr/0017). Internal teardown never refuses.
- Working bundles of viewers that ended (closed or crashed) accumulate; which to offer back
  and which to delete is for the session cleanup.
- `keep = TRUE` does not stop `snapshotDelete()`. A bundle whose snapshot was deleted opens
  with its own state but no object; how to warn before that happens is open.
- GiottoDisk should name `lens/` in its project layout, so nothing in it (pruning, migration)
  treats the folder as unknown.

## Alternatives considered

- **`save_state(path)` anywhere (#21):** a save away from its project points at a snapshot it
  cannot protect, and nothing finds it from the start page.
- **Inside the snapshot's folder, `giottosave/<tag>/`:** that folder is GiottoDisk's, and
  ownership and descriptions stay out of GiottoDisk's records; several bundles can point at
  one snapshot.
- **In the giotto object:** every Lens save becomes a snapshot save, and viewer config enters
  the object.
- **One file (zip, `qs2`):** the contents are mixed JSON and parquet, written atomically as a
  folder; a single file is no more portable, since a bundle is useless without its project.
- **In `tools::R_user_dir()`:** per user and per machine; other writers on the project never
  see it.
- **Working metadata as vault artifacts:** pruned unless a snapshot reaches them.
- **The temp folder itself in the project:** the served folder becomes writable by every
  writer of the project. It also gains little: most of the work is in R's memory, and most of
  the folder is derived or cache.
- **Working metadata in the project only, served by R's call handler from a list of files R
  wrote:** one write instead of two, but those reads move onto R's main thread.
- **Pulls stored as item keys, read again on open:** smaller bundles, but opening needs the
  daemon and the snapshot loaded (about 12 s cold on the Atera section, then about 0.5 s per
  item), and pulls need a path of their own.
- **Copy into the bundle only on save:** an export step, and nothing survives a crash.

## References

Issue #21; adr/0006, adr/0017, adr/0018, adr/0019, adr/0024, adr/0025; SECURITY.md;
GiottoDisk adr/0024 (`snapshot.json`), adr/0025 (grace period); first prototype 792c102
(`serve_atlas()`), its replacement 2996cc3 and 63d0cfe; `.links_outside()` in `R/server.R`.
