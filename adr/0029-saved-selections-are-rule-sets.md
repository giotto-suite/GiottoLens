# 0029. Saved selections are rule sets, restored editable

- **Status:** Proposed
- **Date:** 2026-11-20
- **Supersedes:** 0020 in part (regions as sets of cell IDs, the Regions panel)
- **Superseded by:** —

## Context

adr/0020 saved a selection as a region: the cell IDs it selected. Selecting a region set one
`ids` rule from R (source `r`), so the page showed "from R" and the rules behind it (a
lasso, a histogram range, the table filter) were gone: none could be moved, widened or
dropped. A selection is made of rules (adr/0001), and R holds them with their sources and
combine mode, so they can be kept as they are.

## Decision

A saved selection is a name, the selection's rules by source, and their combine mode, held
by R for the object shown (`save_selection()`, `selections()`, `restore_selection()`,
`remove_selection()`). Restoring one replaces the selection's rules with them, each under
its own source, and sets the mode: the first `set_rule` replaces, the rest add. Its cells
are what its rules select now: the count the page shows, `selections(name)` and
`compare_selections()` evaluate them when asked. They are saved in `state.json` with the
rest of the work, through the same checks as the selection's rules on `open_save()`.
`save_selection(name, rule)` saves a given rule instead, so a set of IDs
(`lens_cells(ids)`) can still be saved. They are not called regions, a word the analysis
uses for the cells it runs on.

## Consequences

- A restored selection can be edited like the one saved: a lasso moved, a range dragged.
- Its cells can change: a rule on a metadata column follows a new table, and one on a column
  no longer there makes `.eval_rule()` fail; `open_save()` drops such rules, and a saved
  selection left with none. `ids` rules name cells by position and are dropped when the
  cells differ, as the selection's are.
- A comparison's cells are taken when it runs, not when the selection was saved.
- The page gets each set's rules (`selections` message), so `ids` rules travel as bitmasks;
  acceptable at these counts, revisit if saved selections grow to dozens of `ids` rules on
  millions of cells.
- Protocol 8: `regions`/`region` became `selections`/`selection`. Bundles from before keep
  their regions in `regions.parquet`, which is no longer read.

## Alternatives considered

- **Keep both, rules and the IDs they selected:** the IDs answer "what did I save" when the
  metadata changes, but two truths disagree as soon as it does, and the IDs alone could not
  be restored as rules.
- **One `set_rules` message for the whole set:** one recompute on the page instead of one
  per rule, but a protocol change for what a short run of `set_rule` already does; R's rule
  count (`seq`) keeps intermediate selections from reaching R.

## References

`R/selections.R`, `R/viewer.R` (`save_selection()`, `apply_rule_set()`, `saved_msg()`,
`restore_state()`), `inst/viewer-src/panels/saved.ts`, `panels/saved-model.ts`;
`tests/testthat/test-selections.R`, `test-bundle.R`; adr/0001, adr/0020, adr/0027.
