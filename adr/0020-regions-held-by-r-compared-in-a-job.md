# 0020. Regions are held by R and compared in a job; a picked gene colours by item key

- **Status:** Proposed
- **Date:** 2026-11-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Comparing two groups of cells needs expression, which the page does not have: the browser
holds centroids, pushed metadata and items it was given (adr/0003, adr/0024). R's main
thread serves the page, so a test run there freezes the viewer for its duration. On the
400 µm MERSCOPE field (1,933 cells, 750 genes, GiottoDisk) a two-group `findScranMarkers()`
takes 0.2 s; a whole section is larger by two to three orders of magnitude in cells.

The first version of this (PR #57) had its own callr session that wrote to a scratch source,
and its own way to colour by a gene: one gene table at a time and a "values" menu. Jobs
(adr/0025) and item keys (adr/0024) now cover both.

## Decision

- **Regions** are named sets of cell IDs that `LensViewer` holds for the object shown. The
  page mirrors their names and counts (`regions`) and acts on them with the `region` ask.
  They count as Lens work for `set_object()`.
- **A comparison** of two regions, or one and every other cell, is a job over the object the
  jobs' daemon holds: `Giotto::findScranMarkers()` on a copy with a group column added. The
  expression source is chosen from the catalog by name (`values`, default `"normalized"`).
  The result is docked as a pushed volcano panel, and its table is kept in R
  (`de_results()`). The `region` ask is answered when the job ends, and the panel cancels it
  by the job's `ref`, as the Data panel does a pull.
- **A gene clicked in the volcano plot** (a pushed spec's `pick` param, `panel_pick`) colours
  that page's cells by the item key of that gene in the comparison's expression source. Its
  values are read like any item, into the item cache, not the metadata.
- **The Regions panel** is a control in the `sources` slot, a tab next to the Data panel,
  shown for a giotto object. Saving a region brings it forward.

## Consequences

- The viewer stays responsive while a test runs. It shows in the jobs popover and can be
  cancelled there or from the panel.
- One process loads the object, shared with item reads and pulls. Nothing goes to a scratch
  source.
- Choosing raw or normalized values is choosing a catalog source, as in the picker. There is
  no gene box and no `color_by_gene()`: the picker and `color_by(key)` do it.
- Only objects shown from a snapshot can be compared; layers passed without a giotto object
  cannot.
- The test is scran's t-test only, the one that streams on GiottoDisk; a rank test would
  need the regions' matrix in memory.
- Regions are not in the saved config. A reload gets them from R; a new R session does not.
  Keeping them belongs to Lens saves.

## Alternatives considered

- **A callr session per viewer, as in PR #57.** It was a second process loading the same
  object, with its own queue and a scratch source. Replaced by adr/0025.
- **A message per action (`region_action`) with status messages.** Fire and forget: errors
  needed a status channel of their own. An ask answers each action, errors included.
- **Regions as drawn annotations only.** No new state, but clusters and brushed cells could
  not be compared.
- **Wilcoxon as well.** It needs every cell of both regions in memory; left out to keep one
  code path that works on disk and in memory alike.

## References

`R/regions.R`, `panels/regions.ts`, `panels/regions-model.ts`, `panels/spec.js` (`pick`),
`tests/testthat/test-regions.R`; adr/0024, adr/0025.
