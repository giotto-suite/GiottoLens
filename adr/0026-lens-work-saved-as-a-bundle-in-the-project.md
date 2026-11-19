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

**What a bundle holds.** Only what exists in the viewer and cannot be derived from the
snapshot:

- `bundle.json`: format version, created, creator, the viewer's session id, the snapshot's
  tag, `objUID()`, spatial unit and feature type, and a cell fingerprint (cell count and a
  hash of the cell IDs). Description and labels are rewritten in place, atomically.
- the config (layers, images, genes by name, colour-by item keys, tool settings, the panel
  layout, the camera), the selection rules, the annotations and a registration in progress,
  as JSON;
- pushed panels, spec as JSON and data as parquet;
- working metadata (pulls and ad-hoc results kept as columns, with their history) as
  parquet. It lives in the bundle, not the vault: the snapshot does not reach it, so in the
  vault it would be pruned. Exporting a column into a giotto snapshot is a separate, explicit
  step.

Not stored: the stores, the cell table and the manifest (derived from the snapshot), the
item cache, the access token and the URL. Rules that list cells by position apply only when
the fingerprint matches; other rules carry over.

**Opening a bundle never serves it.** R reads the bundle, checks it, and writes what the page
needs into the viewer's temp folder or sends it over the WebSocket, as for a pushed panel.
The server keeps serving only the viewer, the mounted stores, the image files and the temp
folder. The temp folder stays in `tempdir()`: it is served, so it is never in the project.

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
- Anyone who can read the project can read its bundles, as they can its data.
- Once saves exist, only work changed since the last save counts as work: `set_object()`
  without `discard`, `close(discard = FALSE)` and `launch_lens(port =)` over a running viewer
  refuse only that (#21, adr/0017). Internal teardown never refuses.
- A "last session" bundle per project, kept for recovery after a crash, is a bundle like any
  other.
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

## References

Issue #21; adr/0006, adr/0017, adr/0018, adr/0019; SECURITY.md; GiottoDisk adr/0024
(`snapshot.json`), adr/0025 (grace period); first prototype 792c102 (`serve_atlas()`), its
replacement 2996cc3 and 63d0cfe.
