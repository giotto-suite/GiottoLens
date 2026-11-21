// Opens the images listed in the manifest as Viv pixel sources, one per
// pyramid level. Each image is one TIFF file (R's .image_source()), page 1.
// Levels come from the file itself: SubIFDs (OME-TIFF, Xenium) or reduced-
// resolution IFDs after the first (COG overviews). The OME-XML is not read:
// Xenium's per-channel files each describe all channels of the set (adr/0008).
// Whether an image is RGB also comes from the file (imageKind()).
import { dataUrl } from '../core/base.ts';
import { fromUrl, GeoTIFFImage } from 'geotiff';
import { TiffPixelSource } from '@vivjs/loaders';
import { Matrix4 } from '@math.gl/core';
import type { ImagePool } from './img-pool.ts';
import { pixelToData, fitPlacement, matrix4, type Affine, type Extent } from './registration.ts';

export interface ImageEntry {
  name: string;
  url: string;
  bytes: number;
  extent: { xmin: number; xmax: number; ymin: number; ymax: number };
  // An affine on top of the extent (giottoAffineImage): x' = a x + b y + c,
  // y' = d x + e y + f, as [a, b, c, d, e, f]
  affine?: number[];
  // 'fit': an image without a place in data coordinates yet (one to
  // register), drawn inside the data's extent instead of at `extent`
  place?: 'fit';
}

export interface LensImage {
  entry: ImageEntry;
  rgb: boolean;                  // colour image: drawn as is, no colour or contrast
  levels: TiffPixelSource<string[]>[];
  width: number;
  height: number;
  transform: Affine;             // image pixels (level 0) → data coordinates
  modelMatrix: Matrix4;          // the same, for deck.gl
  contrast: [number, number];    // default display range
  domain: [number, number];      // range the contrast controls span
}

const DTYPES: Record<string, string> = {
  '1:8': 'Uint8', '1:16': 'Uint16', '1:32': 'Uint32',
  '2:8': 'Int8', '2:16': 'Int16', '2:32': 'Int32', '3:32': 'Float32',
};
const LABELS = ['t', 'c', 'z', 'y', 'x'] as any;
const RGB_LABELS = ['t', 'c', 'z', 'y', 'x', '_c'] as any;

// Without tiles or a pyramid, Viv reads the whole image as one tile at every
// zoom; past this size that is too much to fetch and decode, and beyond what
// a GPU texture holds. Such files are refused rather than hanging the tab.
const MAX_WHOLE = 4096;
export function layoutProblem(width: number, height: number, tiled: boolean, levels: number): string | null {
  if (Math.max(width, height) <= MAX_WHOLE) return null;
  if (!tiled) return `${width} x ${height} pixels in strips, not tiles; save it as a COG or tiled pyramidal TIFF`;
  if (levels < 2) return `${width} x ${height} pixels without a pyramid (overviews); save it as a COG or tiled pyramidal TIFF`;
  return null;
}

// TIFF PhotometricInterpretation values
const PHOTOMETRIC = { minIsBlack: 1, rgb: 2, palette: 3, ycbcr: 6 };

// 'rgb' when the file says it is a colour image: 3 or 4 samples of 8 bits
// in RGB, or YCbCr (JPEG-compressed RGB). 'channel' for one sample of any
// supported type. Otherwise the reason it cannot be shown.
export function imageKind(fd: Record<string, any>): 'rgb' | 'channel' | { error: string } {
  const spp = fd.SamplesPerPixel ?? 1;
  const bits = fd.BitsPerSample?.[0];
  const pi = fd.PhotometricInterpretation;
  if (spp === 1) {
    if (pi === PHOTOMETRIC.palette) return { error: 'palette (indexed-colour) images are not supported' };
    return DTYPES[`${fd.SampleFormat?.[0] ?? 1}:${bits}`] ? 'channel' : { error: `${bits}-bit pixels are not supported` };
  }
  if ((spp === 3 || spp === 4) && (pi === PHOTOMETRIC.rgb || pi === PHOTOMETRIC.ycbcr))
    return bits === 8 ? 'rgb' : { error: `${bits}-bit RGB is not supported; only 8-bit` };
  return { error: `${spp} samples per pixel that are not RGB (multi-channel files are not supported yet)` };
}

// `box`: the data's extent, where an image with `place: 'fit'` is drawn
// Per-sample tags (BitsPerSample, SampleFormat) with fewer values than
// SamplesPerPixel: the first value holds for every sample, as libtiff reads
// them. geotiff indexes them by sample.
export function fillPerSample(fd: Record<string, any>) {
  const n = fd.SamplesPerPixel ?? 1;
  for (const k of ['BitsPerSample', 'SampleFormat']) {
    const v = fd[k];
    if (v?.length && v.length < n) fd[k] = Array.from({ length: n }, (_, i) => v[i] ?? v[0]);
  }
  return fd;
}

export async function openImage(entry: ImageEntry, pool: ImagePool, box?: Extent): Promise<LensImage> {
  const url = dataUrl(entry.url);
  const tiff = await fromUrl(url);
  const base = await tiff.getImage(0);
  const levels = [base, ...(await reducedLevels(tiff, base))];
  for (const img of levels) fillPerSample(img.fileDirectory);
  const fd = base.fileDirectory;
  const problem = layoutProblem(base.getWidth(), base.getHeight(), !!fd.TileWidth, levels.length);
  if (problem) throw new Error(problem);
  const kind = imageKind(fd);
  if (typeof kind === 'object') throw new Error(kind.error);
  const rgb = kind === 'rgb';
  const dtype = rgb ? 'Uint8' : DTYPES[`${fd.SampleFormat?.[0] ?? 1}:${fd.BitsPerSample[0]}`];
  const tileSize = base.getTileWidth();

  // An RGB source has a trailing sample dimension, which Viv draws as colour
  // with the file's PhotometricInterpretation (it converts YCbCr itself)
  const meta = rgb ? { photometricInterpretation: fd.PhotometricInterpretation } : {};
  const sources = levels.map(img => new TiffPixelSource(
    () => Promise.resolve(img), dtype as any, tileSize,
    rgb ? [1, 1, 1, img.getHeight(), img.getWidth(), fd.SamplesPerPixel] : [1, 1, 1, img.getHeight(), img.getWidth()],
    rgb ? RGB_LABELS : LABELS, meta as any, pool as any,
  ));

  const width = base.getWidth(), height = base.getHeight();
  // Row 0 is the top of the image (ymax); y grows upward in the view. A
  // flip, rotation or registration then applies on top
  const transform = entry.place === 'fit' && box ? fitPlacement(width, height, box)
    : pixelToData(entry.extent, width, height, entry.affine);
  const modelMatrix = new Matrix4(matrix4(transform));

  if (rgb) return { entry, rgb, levels: sources, width, height, transform, modelMatrix, contrast: [0, 255], domain: [0, 255] };
  const { contrast, domain } = defaultContrast(await contrastSample(sources), dtype);
  return { entry, rgb, levels: sources, width, height, transform, modelMatrix, contrast, domain };
}

// Full-resolution tiles the default contrast is taken from. Each level of a
// pyramid averages the one above, which keeps the mean but pulls the bright
// tail down (to under half by the smallest level of a Xenium morphology
// image), so the smallest level only chooses where to look
const SAMPLE_TILES = 8;

async function contrastSample(sources: TiffPixelSource<string[]>[]): Promise<ArrayLike<number>> {
  const selection = { t: 0, c: 0, z: 0 };
  const small = await sources[sources.length - 1].getRaster({ selection });
  if (sources.length === 1) return small.data as ArrayLike<number>;
  const [h, w] = sources[0].shape.slice(-2);
  const tiles = sampleTiles(small.data as ArrayLike<number>, small.width, small.height, w, h, sources[0].tileSize, SAMPLE_TILES);
  if (!tiles.length) return small.data as ArrayLike<number>;
  const got = await Promise.all(tiles.map(([x, y]) => sources[0].getTile({ x, y, selection })));
  const out = new (got[0].data.constructor as any)(got.reduce((n, t) => n + t.data.length, 0));
  let at = 0;
  for (const t of got) { out.set(t.data, at); at += t.data.length; }
  return out;
}

// Tiles (x, y) of a w x h full-resolution level whose centre falls on tissue
// in the smallest level (`small`, sw x sh): at or above its median nonzero
// pixel. `n` of them spread evenly in reading order, so the same file always
// gives the same defaults
export function sampleTiles(small: ArrayLike<number>, sw: number, sh: number,
                            w: number, h: number, tile: number, n: number): [number, number][] {
  const nz = Float64Array.from(Array.prototype.filter.call(small, (x: number) => x > 0) as number[]).sort();
  if (!nz.length) return [];
  const thr = nz[Math.floor(nz.length / 2)];
  const cand: [number, number][] = [];
  for (let y = 0; y < Math.ceil(h / tile); y++)
    for (let x = 0; x < Math.ceil(w / tile); x++) {
      const cx = Math.min(w, (x + 0.5) * tile), cy = Math.min(h, (y + 0.5) * tile);
      const v = small[Math.min(sh - 1, Math.floor(cy / h * sh)) * sw + Math.min(sw - 1, Math.floor(cx / w * sw))];
      if (v > 0 && v >= thr) cand.push([x, y]);
    }
  const k = Math.min(n, cand.length);
  return Array.from({ length: k }, (_, i) => cand[Math.floor((i + 0.5) * cand.length / k)]);
}

// Viv expects each level to halve the one above and share its tile size;
// stop at the first that does not
async function reducedLevels(tiff: any, base: GeoTIFFImage): Promise<GeoTIFFImage[]> {
  const out: GeoTIFFImage[] = [];
  const subIFDs = base.fileDirectory.SubIFDs as number[] | undefined;
  let candidates: GeoTIFFImage[] = [];
  if (subIFDs?.length) {
    for (const offset of subIFDs) {
      const ifd = await tiff.parseFileDirectoryAt(offset);
      candidates.push(new GeoTIFFImage(ifd.fileDirectory, ifd.geoKeyDirectory, base.dataView,
        tiff.littleEndian, tiff.cache, tiff.source));
    }
  } else {
    const n = await tiff.getImageCount();
    for (let i = 1; i < n; i++) {
      const img = await tiff.getImage(i);
      // NewSubfileType bit 0: reduced resolution; bit 2: a mask
      if ((img.fileDirectory.NewSubfileType ?? 0) !== 1) break;
      candidates.push(img);
    }
  }
  let prev = base;
  for (const img of candidates) {
    const halves = Math.abs(img.getWidth() - prev.getWidth() / 2) <= 1 &&
                   Math.abs(img.getHeight() - prev.getHeight() / 2) <= 1;
    if (!halves || img.getTileWidth() !== base.getTileWidth()) break;
    out.push(img);
    prev = img;
  }
  return out;
}

// The 0.5th to 99.9th percentile of nonzero pixels (zero is usually padding
// or empty slide), and a control range up to twice the brightest pixel,
// since tiles outside the sample may be brighter
export function defaultContrast(data: ArrayLike<number>, dtype: string) {
  const v = Float64Array.from(Array.prototype.filter.call(data, (x: number) => x > 0) as number[]).sort();
  const top = dtype === 'Uint8' ? 255 : dtype === 'Uint16' ? 65535 : Infinity;
  if (!v.length) return { contrast: [0, 1] as [number, number], domain: [0, Math.min(top, 1)] as [number, number] };
  const q = (p: number) => v[Math.min(v.length - 1, Math.floor(p * v.length))];
  const lo = q(0.005), hi = Math.max(q(0.999), lo + 1);
  return {
    contrast: [lo, hi] as [number, number],
    domain: [0, Math.min(top, Math.max(hi, v[v.length - 1]) * 2)] as [number, number],
  };
}
