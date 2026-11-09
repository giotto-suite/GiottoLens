# 0017. Analysis mode runs the Giotto steps in a persistent R worker, as a cached step tree

- **Status:** Proposed
- **Date:** 2026-11-04
- **Supersedes:** —
- **Superseded by:** —

## Context

`launch_lens_analysis()` lets a user change the parameters of the first steps of a
Giotto analysis (QC filter to cell-type labels) from the viewer and see the effect.
Every R call blocks httpuv's event loop: while `runUMAP()` runs in the main session the
viewer gets no replies, and a second change cannot interrupt the first. On the 400 µm
MERSCOPE field (815 features, 2090 cells, GiottoDisk `parquetExprStore`) the whole chain
takes about 6 s (filter 1.2 s, UMAP 2.5 s, markers 1.3 s, others ≤ 0.3 s), so most changes
should return in a second or two if only the affected steps rerun.

GiottoDisk adopts stores created by `createNearestNetwork()` into the object's vault
(`artifacts/` and `_pending/`) as they are set, so running steps on an object loaded
from a vault writes to that vault. Copying the vault does not help: loaded stores keep
absolute paths into the original.

`normalizeGiotto()` refuses z-score scaling on a `parquetExprStore`.

## Decision

The steps form a tree (qc filter → normalize → hvf → pca → {umap, network → leiden →
markers → labels}); each step's cache key is its parameters plus its parent's key. A
change marks that step and its descendants stale. A persistent `callr::r_session` holds
the loaded object and the outputs of the current keys, runs one step per call, and
returns only small results (metadata columns, coordinates, tables). The main session
polls it with `later`, pushes results to the viewer as each step finishes, and interrupts
the worker when the step it is running goes stale. The worker's object gets a fresh
`gDirSource` in a session temp directory (`sourceCreate()`, `setArtifactDumpDir()`), so
new stores are written there and the vault is only read.

## Consequences

- The viewer stays responsive while a step runs, and a newer change cancels older work.
- The object exists twice (main session for drawing, worker for analysis); for disk
  objects this is small, for in-memory objects it is a full copy.
- The worker must find Giotto and GiottoDisk on the same library paths as the main session.
- Step functions are sent to the worker by value, so they reference packages with `::`.
- Scaling is offered only when the raw expression is not a `parquetExprStore`.
- Revisit when GiottoDisk supports detaching a source, or when steps on whole sections
  take minutes (progress within a step, finer cancellation).

## Alternatives considered

- **Run in the main session** — simplest; freezes the viewer and cannot cancel.
- **`mirai` daemons** — not installed in the target library; `callr` already is.
- **Rerun the whole chain on any change** — 6 s on the mini field for every change, and
  minutes on a whole section.
- **Copy the vault to scratch** — stores still resolve to the original vault.

## References

`R/analysis.R`, `R/analysis-steps.R`, `inst/viewer-src/panels/analysis.js`.
