# 0012. Images are registered by landmarks in the browser; unreadable files are converted once

- **Status:** Proposed
- **Date:** 2026-11-03
- **Supersedes:** 0008 in part (the rejected "convert to COG on launch")
- **Superseded by:** —

## Context

Post-Xenium H&E and IF images arrive unaligned to the data. Xenium Explorer aligns them by
landmark pairs between the image and the DAPI image and exports a 3 x 3 matrix
(`imagealignment.csv`, image pixels to DAPI pixels) and the pairs (`keypoints.csv`,
`fixedX,fixedY,alignmentX,alignmentY`). Giotto reads that matrix with `read10xAffineImage()`.
The viewer already draws a `giottoAffineImage` from its `@affine` on top of the raster
extent (adr/0008). Matching points by eye needs the image to move as pairs are placed.

H&E files come in layouts the viewer refuses (adr/0008): strips, no pyramid, levels that do
not halve (SVS), planar samples, PNG or JPEG. Refusing them leaves the user to convert by hand.

## Decision

The browser holds the registration (`config.registration`): the image, the reference, a base
transform (placement before a fit), the orientation of the image's pane (flips, quarter
turns) and landmark pairs, moving points in image pixels and fixed points in data
coordinates. While registering, the image is shown in its own pane (a second deck.gl Deck)
beside the main view, which shows the reference. From three complete pairs it fits a least-squares
affine (`data/registration.ts`) and draws the image with it; before that, with the base.
Every change goes to R as `registration_update`. R turns the transform into Xenium Explorer
CSVs through the reference image's own pixel transform, and into a `giottoAffineImage`
(`.registered_image()`).

R checks each image file with the viewer's rules (`.tiff_problem()`, mirroring `imageKind()`,
`layoutProblem()` and `reducedLevels()`). A file that fails is written once as a COG with
GDAL (terra) to `getOption("GiottoLens.image_cache")`, default
`tools::R_user_dir("GiottoLens", "cache")`, keyed by path, size and modification time, and
the copy is served. VRT files are still skipped.

## Consequences

- The fit equals Giotto's `calculateAffineMatrixFromLandmarks()` (9e-13 on 12 noisy pairs);
  on exact pairs it recovers the 10x matrix of the breast H&E (`test/registration.test.ts`).
- The fit is affine (6 parameters); Xenium Explorer's own fit may differ for the same pairs.
- Flips and rotations orient the image's pane only; the fit does not depend on them.
- Two Decks draw while registering; the image's tiles load in its pane, and in the main view
  only with the preview on.
- `.tiff_problem()` and `data/images.ts` must change together.
- A converted whole-section H&E costs minutes once and its size again on disk, outside the
  data; the cache is not pruned.
- The roadmap's registration plugin (sample to sample, fitted in R) is not this; it can reuse
  `data/registration.ts`.

## Alternatives considered

- **Fit in R and send the transform back:** a round trip per drag and nothing to draw while R
  is busy; R still gets every change and can refit.
- **One view, the image over the reference, hidden for the fixed point:** tried first; with
  the two images on top of each other, matching points was hard to follow.
- **Two views in one Deck (`layerFilter`):** every view state, tile query and screen-to-data
  conversion in the viewer assumes one view.
- **Convert next to the data:** writes into data folders, against the serving invariant.
- **Convert in a session temp directory:** a whole-section H&E converted on every launch.

## References

`inst/viewer-src/data/registration.ts`, `ui/registration.ts`, `render/landmarks.ts`,
`R/registration.R`, `R/images.R`; `test/registration.test.ts`,
`tests/testthat/test-registration.R`, `test-images.R`, `test-e2e.R`.
10x Genomics, Image Alignment in Xenium Explorer (keypoints and matrix CSV formats).
