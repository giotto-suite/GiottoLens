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
(adr/0024) and job progress files (adr/0025), all served. R deletes `tempdir()` when it exits
normally; after a crash the folder is left under a random name nothing can find.

A project is loose files. Who can read or change it is decided by the operating system's
permissions on its folder, for the data, the snapshots and anything Lens writes alike.

Two things limit where a save can go. GiottoDisk's `sourcePrune()` keeps only what a live
snapshot reaches, so a save that points into the vault on its own protects nothing. And the
first prototype (GiottoAtlas, 792c102) wrote its viewer files and manifest into an `atlas/`
folder in the data's root and served that whole root without a token; the in-process server
(2996cc3) and the token path (adr/0006) replaced it with mounted stores and a temp folder.
What the server serves must not grow back to the whole project directory.

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

**The working bundle is the served session folder.** Each viewer keeps its work in
`<project>/lens/session-<session id>/` and the server serves that folder to the page, as
`work/`. When an object is shown, R writes its `bundle.json`; R rewrites `state.json` and
`config.json` when they change, checking about once a second; working metadata and panel data
are written there once, as parquet, and read by the page from there. Each file is replaced
atomically (temp file, then rename). A save copies the working bundle, only the files its
`state.json` points to, into `lens/<name>.<id>/` within the project; nothing is exported.
Opening a save shows its snapshot, then copies its files into the viewer's working bundle and
restores its work; parts in cell order (metadata, rules naming cells by position, panels
linked to cells) only when the cell fingerprint matches.

**Closing keeps work not saved.** `close()` leaves the working bundle in the project when it
holds work changed since the last save or opening, and `open_save()` takes it over later (and
then removes it); `close(discard = TRUE)` deletes it, as does `close()` with nothing unsaved.
Since closing loses nothing, it does not refuse, nor does `launch_lens(port =)` over a running
viewer, which closes it. `bundle.json` of a working bundle records the machine and process
that write it, so one whose viewer still runs is neither opened nor deleted by another.

Only disposable files stay in `tempdir()`, on a second served path: they are rewritten per
load or are a cache, and on a project on a network file system the item cache would be slow.

| File | Where |
|---|---|
| config, rules, annotations, registration (from R's memory) | working bundle, JSON |
| `metadata/` (pushed, pulls, ad-hoc) | working bundle: values, plus key and history for pulls |
| `panels/` | working bundle: data, plus the spec from R's memory |
| `manifest.json` | temp: derived from the snapshot |
| `cells-<load>.parquet` | temp: derived; the bundle keeps only the cell fingerprint |
| `items/` | temp: a cache |
| `jobs/<id>.progress` | temp: transient |

**The folder is named by the session id, never the token.** The token is the credential for
the running viewer; in a folder name, anyone who can list the project would learn it and could
read and drive that viewer. The session id is random and independent of the token (adr/0018).
Where files sit on disk is invisible to HTTP clients: someone without the token cannot reach
them through the server wherever they are, so serving from the project protects as much
against outside access as serving from `tempdir()`.

**Access is the project's.** GiottoLens has no users and no per-save access control: anyone
who can read the project can read its bundles and working bundles, as they can its data.
Anyone who can write it is trusted as a collaborator, as they already are by the stores the
viewer serves and the snapshots `loadGiotto()` deserializes. Per-user permissions would need
identities and a process that checks them, a hosted app, which GiottoLens is not. What
GiottoLens guards is narrower: it must not give access beyond what the file system gives.

- The token and the localhost bind keep anyone who cannot read the files from reading them
  through the viewer.
- The server does not follow a symbolic link out of what it serves. Stores are checked once,
  when mounted (`.links_outside()`); the working bundle, written while it is served, goes
  through R's file handler, which checks each file's real path on every request. Its files
  are small, so reading them on R's thread costs little.
- A bundle the page asks for is opened only if its name is one R listed for the open
  project; a name is never joined into a path unchecked.
- A file is read from a bundle only if it is a regular file inside it (`.bundle_file()`).
  Opening or saving copies files into the project, where others can read them; a link
  placed in a bundle would otherwise copy a file from elsewhere there.
- Nothing secret goes in a bundle: not the token, not the URL.

Bundles are JSON and parquet, never `rds` or `qs2`: they can be read without R, and loading
one runs no deserialization of R objects. Rules are parsed into rule objects and checked,
never evaluated as code; labels, descriptions and panel specs are shown as text in the page,
never as HTML.

## Consequences

- Lens writes into the project in three ways: hand-over snapshots (adr/0018), job outputs
  in the vault, and bundles in `lens/`. SECURITY.md says so.
- While a viewer runs, part of what it serves is in the project. The start page lists the
  working bundles of viewers that ended, as work not saved, and never those still running.
- Seeing which saves are yours needs an owner on saves and snapshots: a label for browsing,
  not access control (a preference, and a field in GiottoDisk's `snapshot.json`).
- Only work changed since the last save or opening counts as work: `set_object()`,
  `checkout()` and `open_project()` without `discard` refuse only that (adr/0017).
- An analysis is not saved yet: it always counts as work not saved.
- Working bundles of viewers that ended accumulate until opened or deleted
  (`delete_save()`); cleaning them up on a schedule is for later.
- `keep = TRUE` does not stop `snapshotDelete()`. A save whose snapshot was deleted does not
  open; R names the snapshot. How to warn before that happens is open.
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
- **Serve from `tempdir()` and keep a working bundle in sync in the project:** two copies of
  the same files, every write done twice. `tempdir()`'s private permissions guard only against
  other local users, which the project's permissions decide anyway.
- **The working bundle readable by its owner only (`chmod 0700`):** a privacy the project does
  not otherwise have, and no effect on Windows.
- **The folder named by the token:** gives the credential to anyone who can list the project.
- **Everything in the project, the item cache included:** a cache read and written on every
  gene pick, slow on a network file system, in a shared folder.
- **Pulls stored as item keys, read again on open:** smaller bundles, but opening needs the
  daemon and the snapshot loaded (about 12 s cold on the Atera section, then about 0.5 s per
  item), and pulls need a path of their own.
- **Copy into the bundle only on save:** an export step, and nothing survives a crash.

## References

Issue #21; adr/0006, adr/0017, adr/0018, adr/0019, adr/0024, adr/0025; SECURITY.md;
GiottoDisk adr/0024 (`snapshot.json`), adr/0025 (grace period); first prototype 792c102
(`serve_atlas()`), its replacement 2996cc3 and 63d0cfe; `.links_outside()` in `R/server.R`.
