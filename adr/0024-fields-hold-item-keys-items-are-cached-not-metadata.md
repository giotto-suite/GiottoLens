# 0024. A field holds an item key; items are cached by the page, not added to the metadata

- **Status:** Proposed
- **Date:** 2026-11-18
- **Supersedes:** —
- **Superseded by:** —

## Context

The catalog lists what the object shown holds by source: cell metadata of a feature type,
each expression matrix, each spatial enrichment, each dim reduction. Its first use was the
pull: queued items become metadata columns. Colouring cells by one gene that way adds a
column per gene. The colour-by menu, the chart menus and the tooltip then fill with gene
names, and each gene has its own colour scale, so a scale set for one is lost on the next.

An object has thousands of genes per matrix (18,090 on the Atera section) and often a raw and
a normalized matrix of the same genes. No dropdown lists that, and a gene name alone does not
say which matrix it is from.

## Decision

A field that shows one value (colour-by first) holds either a metadata column name or an
**item key**: `@` and the slot, feature type, source name, method and item, each
percent-encoded, joined by `/`. It names the item by where it is in the object, not by a
column. `.item_key()` in R and `itemKey()` in the page write the same string; a column name
never starts with `@`.

The page gets an item's values with the `item` ask. R reads it with one `spatValues()` call
into `session/items/`, once per object, and never into the metadata. The page keeps the
items it was given, least recently used first out, while they fit 128 MB, and never drops the
one that colours the cells. Picking means choosing: a **picker** popover from the field's
button lists the metadata and then each catalog source, with a search. Choosing the raw or the
normalized matrix is choosing the source. Items chosen stay in the field's menu as a
"recent" group.

The docked panel that pulls items into the metadata is the **Data** panel. Pulling is
the explicit step that makes columns: tracked by the metadata, exportable, seen by the
charts and the table.

Expression items share one colour scale (`colorScales['@expression']`); others have their
own.

## Consequences

- Menus list what the user made into metadata, plus a short recent list. Genes do not
  accumulate there.
- The key is stable across reloads of the same object, so a saved colour-by item survives a
  reload. A key whose item the object lacks is refused by R.
- The charts, rules and the cell table still take metadata columns only. Moving them to
  fields (and so to items) is the next step. A rule on an item will have to pin it in the
  cache.
- Each read loads the snapshot again in the R session (`gobject()`) until reads move to a
  job worker. `color_by()` with an item reads it before asking the page, so the page's
  request does not wait on that load.

## Alternatives considered

- **Genes as metadata columns** (the pull). Rejected for display, for the reasons above; kept
  as the Data panel's explicit step.
- **One "current gene" slot**, replaced on each pick. Every switch back to an earlier gene
  costs a read, and a gene's source still needs naming.
- **The docked panel as the picker**, armed by a field's button. That is state shared across
  panels, and the panel may be closed or behind another tab. A popover needs neither.
- **A JSON object in `colorBy`.** It would change the saved config's type and every reader
  of `colorBy`, for no gain over a string that cannot collide with a column name.

## References

`data/items.ts`, `data/catalog.ts`, `panels/picker.ts`, `panels/data.ts`, `panels/cells.ts`;
`R/catalog.R` (`.item_key()`, `.parse_item_key()`), `R/viewer.R` (`read_item()`,
`color_by()`).
