# 0008. Images are read by the browser from their TIFF file, JPEG-2000 decoded in workers

- **Status:** Accepted
- **Date:** 2026-10-31
- **Supersedes:** —
- **Superseded by:** 0014 in part (conversion of files the viewer cannot read)

## Context

Giotto objects carry images as giottoLargeImage, a terra raster over a file. Xenium writes
its morphology images as pyramidal OME-TIFFs with 1024 x 1024 JPEG-2000 tiles (compression
34712), one file per channel, each file's OME-XML describing the whole channel set. The suite
writes COGs for images it creates. Viv 0.23 renders 16-bit multiscale images in deck.gl, but
its geotiff (2.1.3) has no JPEG-2000 decoder, and geotiff's worker pool cannot be given one
from the main thread.

## Decision

The browser reads each image's TIFF file directly, by Range, served alone at `image/<k>`.
`.image_source()` names the file (`@file_path`); R adds only the extent. Pyramid levels come
from the file's SubIFDs or COG overview IFDs, one Viv `TiffPixelSource` each. JPEG-2000 is
decoded by OpenJPEG compiled to WASM (`@cornerstonejs/codec-openjpeg`, decode-only build) in
an own worker pool that also runs geotiff's decoders.

## Consequences

- Atera: four images open in 0.24 s and the overview draws in 0.31 s; a jump to full
  resolution with three images loads in 0.62 s. A dense tile takes about 128 ms to decode,
  so decoding has to stay in workers.
- Pixels match GDAL's decode of the same bytes to within 1 on about 1% of pixels (lossy
  wavelet rounding); lossless codestreams decode exactly (`test/images.test.ts`).
- Image tiles go through R's main thread like `data/` (adr/0004): a busy R stalls them.
- Only page 1 of a file, single-channel or 8-bit RGB pages (told apart by their TIFF tags),
  and levels that halve with one tile size.
- 260 KB of WASM in the bundle, loaded only when an image is shown.

## Alternatives considered

- **Decode in R** (GDAL through the GiottoClass VRT, raw tiles to a custom pixel source): no
  codec in the browser and any GDAL format, but every tile's decode would run on R's main
  thread, one at a time, instead of in parallel workers.
- **Convert to COG on launch:** a full re-encode of each image, and a copy of it somewhere.
- **Viv `loadOmeTiff()`:** reads Xenium's per-file OME-XML as four channels in one file.
- **geotiff's own Pool:** fixed decoder set; a failed decode never settles.

## References

`R/images.R`, `R/server.R`; `data/images.ts`, `data/j2k.ts`, `data/img-worker.ts`,
`data/img-pool.ts`, `render/render.js`; design.Rmd "Images".
