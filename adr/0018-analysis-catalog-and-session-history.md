# 0018. Analyses are catalog entries added from a dialog; finished runs are kept for the session

- **Status:** Proposed
- **Date:** 2026-11-11
- **Supersedes:** —
- **Superseded by:** —

## Context

The Analysis panel of `launch_lens_analysis()` ran one fixed step tree (Preprocessing) and then a
second fixed tab (Spatial interactions). More Giotto analyses (spatial genes, co-expression
modules, niches, interaction-changed genes, markers between groups, subclustering, cluster
trees, Harmony integration, enrichment) are to be offered without adding a tab each, and
earlier results are lost when a parameter changes.

## Decision

Each analysis is a catalog entry: a function `.analysis_entry_<id>()` in its own file returning
its id, label, brief, description, inputs, outputs and steps (`R/analysis-catalog.R`). The
catalog is found by name, so an entry is added by adding its file. Steps keep the format of
ADR 0017; step ids are unique across the catalog. Shared steps (`R/analysis-shared.R`):

- `.step_source()` reads the result of the Preprocessing tab's Cell types step or the loaded
  object, by its `from` parameter; its parent is resolved when keys are computed.
- `.step_groups()` keeps the cells with a value in a categorical column (object or Preprocessing)
  as `lens_group`.
- `.step_network()` builds a spatial network named `lens_spatial`.

A step's `view(res, p)` runs in the main session and returns docked panels and tables;
`code(p, up)` returns its R code. Preprocessing is always included and runs automatically; other
entries are added from an Add analysis dialog (description, inputs, outputs, steps with editable
parameters) or `$add()`, run on Run, and are removed with `$remove()`. A menu lists the
included analyses.

Each time no step of an analysis is stale or running, its keys, parameter values, statuses and
step results are recorded as a run (in memory, `getOption("GiottoLens.analysis_history", 10)`
runs per analysis). `$restore_run()` and the History menu set the parameters back and show the
recorded results without running the steps; the worker's cache recomputes inputs when a later
step needs them.

A gene in a result table is shown by asking the worker for its values (`spatValues()`,
normalized when an object of the step, the Cell types step or the Normalize step has them) and
pushing them as the metadata column `expr_<gene>`.

## Consequences

- New analyses need no change to the panel or to `LensAnalysis`.
- Results of several runs are held in the main session; on whole sections a run with per-cell
  columns takes tens of MB.
- History does not survive closing the viewer.
- Protocol 7: `analysis_add`, `analysis_remove`, `analysis_history`, `analysis_feature`,
  `analysis_tables`.
