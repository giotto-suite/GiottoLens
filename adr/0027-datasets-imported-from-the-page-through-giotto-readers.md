# 0027. Datasets are imported from the page through Giotto's readers, in a job of their own

- **Status:** Proposed
- **Date:** 2026-11-19
- **Supersedes:** —
- **Superseded by:** —

## Context

Since adr/0019 the start page opens existing GiottoDisk projects only; making one from a
platform's output folder needed R code (`sourceCreate()`, `createGiotto<Platform>Object(...,
backend = src)`, `snapshotSave()`). Giotto's readers already know each platform's layout:
`importXenium(dir)` finds the transcripts, boundaries, expression, cell metadata, panel and
image files when it is created (`@paths`, `@micron`), and its `create_gobject` closure
carries the defaults of every loading option in its formals. With `backend =`, the same call
writes a disk-backed project (GiottoDisk's `XeniumDiskReader`).

An import of a whole section takes minutes and writes gigabytes. adr/0025's jobs run in one
daemon per viewer that holds the object shown and writes to that object's vault.

## Decision

**R detects, the page edits, R imports.** The page asks `import_detect` (`platform`, `dir`);
R creates the platform's reader without a backend and answers a form: one field per
argument of `createGiotto<Platform>Object()`, filled from the reader's paths and its
`create_gobject` defaults, each path with whether it exists and its size, the reader's
warnings, and a project folder and snapshot name. The page shows it for editing and sends
`import_run` with the edited values. R passes only the arguments whose value differs from
the detected one, so every default stays the reader's. A detection error is the reader's
own error; the form is not filled around it.

**Import is the one page action that creates a project.** The project folder must not
exist, or be an empty folder, and must not be in a cloud-synced folder. The default folder
is preference `import_dir` (else the parent of the project open, else R's working
directory) joined with a name made from the dataset folder.

**The import runs as a job in a daemon of its own**, started for it and stopped when it ends:
it calls `setArtifactDumpDir()`, `sourceCreate()`, the platform's `createGiotto*Object(...,
backend = src)` and `snapshotSave()` (creator `GiottoLens`, kept). It is listed and cancelled
as other jobs are (`job` messages, `cancel_job`), with the reader's messages as its progress
text, and is not cancelled when the object shown changes. A failed or cancelled import
deletes the project folder it created. The answer is the project path and snapshot name;
the page then opens the snapshot with `open`, which asks before dropping Lens work. With
"Run Preprocessing" (on by default), opening that snapshot starts the Analysis panel's
Preprocessing, as a Run would (adr/0021).

`viewer$detect_dataset()` and `viewer$import_dataset()` do the same from R. The form and the
result carry the R code of the import; the page's `import_code` gives it for edited values.

## Consequences

- The page can make R write a new project anywhere the R user can write. The token still
  guards this (SECURITY.md).
- A second daemon runs during an import, loading Giotto and GiottoDisk again (seconds) and
  holding the import's memory, which is released when it stops.
- The form follows the reader: a new argument of `createGiotto<Platform>Object()` needs a
  field. A reader that stops at detection (Giotto's Xenium reader when no expression matrix is
  found) leaves nothing to edit.
- One platform module per reader in `R/import.R`; Xenium first.

## Alternatives considered

- **Detect files in GiottoLens:** a second copy of each reader's layout rules, out of step with
  Giotto as it changes.
- **The viewer's job daemon:** it holds the object shown and its vault as the artifact dump;
  an import would block pulls for minutes and leave the dump pointing at the new project.
- **Import on R's main thread, as `open` loads:** the page and console freeze for minutes and
  it cannot be cancelled.
- **Pass every field to the reader:** the R code shown would repeat each default, and the
  keywords the reader resolves itself (`"cell"`, `"nucleus"`, `"focus"`) would become fixed
  paths.

## References

`R/import.R`, `R/viewer.R` (`detect_dataset`, `import_dataset`, `ask`, `start_job`),
`R/jobs.R` (`.jw_call`), `inst/viewer-src/ui/import.ts`, `inst/viewer-src/ui/start.ts`;
`tests/testthat/test-import.R`, `inst/viewer-src/test/import.test.ts`. Giotto
`importXenium()`, `createGiottoXeniumObject()`; GiottoDisk `importXeniumDisk()`.
