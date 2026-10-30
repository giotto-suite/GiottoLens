// Transcript tile → typed arrays, keeping every `stride`-th point. Runs in a
// worker (data/tx-worker.ts) or, where workers are unavailable, on the main
// thread. data/point-decode.ts does the work; files it cannot read (an
// encoding it does not cover) go through hyparquet instead.
import { tileSource, readColumns } from './parquet.ts';
import { decodePoints, UnsupportedLayout, GENE_NONE } from './point-decode.ts';

export const GENE_UNKNOWN = GENE_NONE;
const COLUMNS = ['x_index', 'y_index', 'feat_ID'];

export interface TileRef { url: string; file?: string; bytes?: number }

export async function decodeTranscriptTile(tile: TileRef, geneIndex: Map<string, number>, stride = 1) {
  const { file, metadata } = await tileSource(tile, COLUMNS);
  try {
    return await decodePoints((a, b) => file.slice(a, b), metadata, geneIndex, stride);
  } catch (e) {
    if (!(e instanceof UnsupportedLayout)) throw e;
  }
  const cols = await readColumns(file, COLUMNS, metadata);
  const xs = cols.x_index ?? [], ys = cols.y_index ?? [], fs = cols.feat_ID ?? [];
  const m = Math.ceil(xs.length / stride);
  const pos = new Float32Array(m * 2);
  const geneIdxs = new Uint16Array(m);
  for (let i = 0, k = 0; i < xs.length; i += stride, k++) {
    pos[k * 2]     = xs[i] ?? NaN;
    pos[k * 2 + 1] = ys[i] ?? NaN;
    geneIdxs[k]    = geneIndex.get(fs[i]) ?? GENE_UNKNOWN;
  }
  return { pos, geneIdxs };
}
