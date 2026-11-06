# 0014. Images are registered by landmarks in the browser

- **Status:** Proposed
- **Date:** 2026-11-03
- **Supersedes:** —
- **Superseded by:** —

## Context

Post-Xenium H&E and IF images arrive unaligned to the data. Xenium Explorer aligns them by
landmark pairs between the image and the DAPI image and exports a 3 x 3 matrix
(`imagealignment.csv`, image pixels to DAPI pixels) and the pairs (`keypoints.csv`,
`fixedX,fixedY,alignmentX,alignmentY`). Giotto reads that matrix with `read10xAffineImage()`.
The viewer already draws a `giottoAffineImage` from its `@affine` on top of the raster
extent (adr/0008). Matching points by eye needs the image to move as pairs are placed.

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

## Consequences

- The fit equals Giotto's `calculateAffineMatrixFromLandmarks()` (9e-13 on 12 noisy pairs);
  on exact pairs it recovers the 10x matrix of the breast H&E (`test/registration.test.ts`).
- The fit is affine (6 parameters); Xenium Explorer's own fit may differ for the same pairs.
- Flips and rotations orient the image's pane only; the fit does not depend on them.
- Two Decks draw while registering; the image's tiles load in its pane, and in the main view
  only with the preview on.
- An image file the viewer cannot read by tile (adr/0008) cannot be registered here; it
  needs converting first.
- The roadmap's registration plugin (sample to sample, fitted in R) is not this; it can reuse
  `data/registration.ts`.

## Alternatives considered

- **Fit in R and send the transform back:** a round trip per drag and nothing to draw while R
  is busy; R still gets every change and can refit.
- **One view, the image over the reference, hidden for the fixed point:** tried first; with
  the two images on top of each other, matching points was hard to follow.
- **Two views in one Deck (`layerFilter`):** every view state, tile query and screen-to-data
  conversion in the viewer assumes one view.

## References

`inst/viewer-src/data/registration.ts`, `ui/registration.ts`, `render/landmarks.ts`,
`R/registration.R`, `R/images.R`; `test/registration.test.ts`,
`tests/testthat/test-registration.R`, `test-images.R`, `test-e2e.R`.
10x Genomics, Image Alignment in Xenium Explorer (keypoints and matrix CSV formats).
