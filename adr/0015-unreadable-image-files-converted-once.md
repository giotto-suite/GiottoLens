# 0015. Image files the viewer cannot read are converted once to a cached COG

- **Status:** Proposed
- **Date:** 2026-11-03
- **Supersedes:** 0008 in part (the rejected "convert to COG on launch")
- **Superseded by:** —

## Context

H&E files come in layouts the viewer refuses (adr/0008): strips, no pyramid, levels that do
not halve (SVS), planar samples, PNG or JPEG. Refusing them leaves the user to convert by hand,
and registering such an image (adr/0014) needs it shown first.

## Decision

R checks each image file with the viewer's rules (`.tiff_problem()`, mirroring `imageKind()`,
`layoutProblem()` and `reducedLevels()`). A file that fails is written once as a COG with
GDAL (terra) to `getOption("GiottoLens.image_cache")`, default
`tools::R_user_dir("GiottoLens", "cache")`, keyed by path, size and modification time, and
the copy is served. VRT files are still skipped.

## Consequences

- `.tiff_problem()` and `data/images.ts` must change together; a file R wrongly flags is
  converted although the viewer could read it.
- A converted whole-section H&E costs minutes once, during `launch_lens()`, and its size
  again on disk, outside the data; the cache is not pruned.

## Alternatives considered

- **Convert next to the data:** writes into data folders, against the serving invariant.
- **Convert in a session temp directory:** a whole-section H&E converted on every launch.
- **Loose images added from the GUI, written as COGs into a source vault by a background
  job:** the conversion is owned by the data and does not hold up the launch. Preferred;
  it waits for background jobs and a GUI that adds images.

## References

`R/images.R` (`.tiff_info()`, `.tiff_problem()`, `.viewable_file()`); `tests/testthat/test-images.R`.
