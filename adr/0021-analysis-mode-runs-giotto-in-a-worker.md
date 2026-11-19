# 0021. An analysis runs its Giotto steps as jobs, as a step tree keyed from the snapshot

- **Status:** Proposed
- **Date:** 2026-11-19 (first version 2026-11-04)
- **Supersedes:** —
- **Superseded by:** —

## Context

The Analysis panel lets a user change the parameters of Giotto steps (QC filter to cell-type
labels, and the analyses of adr/0022) from the viewer and see the effect. Every R call on the
main thread blocks the page: while `runUMAP()` runs there the viewer gets no replies, and a
second change cannot interrupt the first. On the 400 µm MERSCOPE field (815 features,
2090 cells, GiottoDisk) the whole Preprocessing chain takes about 6 s (filter 1.2 s,
UMAP 2.5 s, markers 1.3 s, others ≤ 0.3 s), so most changes should come back in a second or
two if only the affected steps rerun.

The first version (PR #59) ran the steps in its own callr session on an `saveRDS()` copy of
the object, wrote the stores the steps made to a scratch source, replaced the viewer's whole
metadata with its own columns, and coloured genes as metadata columns. It was started by its
own function, `launch_lens_analysis()`. The viewer has since gained jobs in a daemon that
holds the object shown (adr/0025), one vault per project, and item keys (adr/0024).

The viewer never follows the worker's state. It shows a snapshot; everything it reads names
its source. What an analysis computes is overlays on that snapshot, or a snapshot of its own
to check out.

## Decision

- **An analysis belongs to the object shown.** `viewer$analysis()` makes it on first call, or
  the page does when the Analysis panel is opened from the "+" menu; it ends when another
  object is shown. Nothing runs until a step is run or a parameter is set. It counts as Lens
  work once a step has run.
- **Steps run as jobs.** The analysis's poll loop calls the viewer's jobs through a small
  adapter (`.AnalysisWorker`). The daemon keeps the analysis (`.lens_a`): its base object (the
  snapshot held for the viewer, with the analysis's unit and type active) and a cache of each
  step's result. Interrupting a stale step is cancelling its job.
- **Steps form a keyed tree.** A step's key is its parameters, with user input by value
  (labels, marker lists, region cells), and its input's key. The root is the snapshot
  (`snapshot:<tag>`). A key always stands for the same result, so the cache, the history and
  item reads can all use it. The cache keeps the current keys and the most recent others,
  within a memory cap (`GiottoLens.analysis_cache_mb`, 4096 MB); an evicted result is
  recomputed from its key's chain.
- **Writes go to the project's vault.** The daemon's artifact dump is the project's; there is
  no scratch source.
- **Results are overlays.** Metadata columns are kept beside pushed and pulled ones
  (`own_columns()`); a column the analysis no longer makes is dropped with the rules on it.
  Charts are pushed panels. A gene from a result table colours the cells by an item key
  whose method names the step result it is read from (`analysis:<hash of the key>`), so the
  analysis's normalized values can be shown before anything is saved.

## Consequences

- The viewer stays responsive while a step runs; steps show in the jobs popover.
- One process holds the object for item reads, pulls, region comparisons and the analysis.
  A gene read waits behind a running step; both can be cancelled.
- `gobject()` returns the last step's object from the daemon, with stores in the vault.
- Keys are session-scoped strings rooted at a snapshot tag. Using them across sessions (a
  snapshot sidecar that records the key of the run it holds) and letting an analysis start
  from any step key or snapshot are next steps; the key form does not need to change for
  either.
- Showing a finished run as the object is a checkout of a snapshot of it (the run-snapshot
  work), not the viewer following the daemon.
- Steps call packages with `::` and the `.lens_*` helpers: they run in the daemon as plain
  functions.

## Alternatives considered

- **Its own callr session, as in PR #59.** A second loaded copy of the object, a second
  queue, and results the viewer could not address. Replaced by jobs.
- **The viewer follows the worker.** The page's cells, rules and masks are indexed by the
  snapshot's cells; a filter step changing the cell set would reindex the page under the
  user, and nothing it showed could be named or saved. Rejected for overlays and checkout.
- **Run in the main session.** Simplest; freezes the viewer and cannot cancel.
- **Rerun the whole chain on any change.** 6 s on the mini field for every change, and
  minutes on a whole section.

## References

`R/analysis.R`, `R/analysis-steps.R`, `inst/viewer-src/panels/analysis.js`; adr/0022,
adr/0024, adr/0025.
