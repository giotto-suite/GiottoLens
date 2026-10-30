// All cells as typed arrays, indexed 0..N-1 in the order R wrote them:
// polygon tiles concatenated in manifest order, so tile t holds cells
// offset .. offset + n - 1. Selections, colours and metadata use this index
// (adr/0002).
import { rangeBuffer, readColumns } from './parquet.ts';

export interface CellTile {
  index: number;        // tile index in the manifest
  offset: number;       // first cell of the tile
  n: number;
  bounds: [number, number, number, number];   // centroid xmin, xmax, ymin, ymax
}

export interface Cells {
  n: number;
  x: Float32Array;
  y: Float32Array;
  tiles: CellTile[];    // sorted by offset
  url: string;
}

export async function loadCells(polyLayer: any): Promise<Cells | null> {
  if (!polyLayer?.cells) return null;
  const url = new URL(polyLayer.cells.url, document.baseURI).href;
  const cols = await readColumns(await rangeBuffer(url), ['x', 'y']);
  const n = polyLayer.cells.n;
  const tiles: CellTile[] = polyLayer.tiles
    .map((t: any) => ({ index: t.index, offset: t.offset, n: t.n, bounds: t.cbounds }))
    .sort((a: CellTile, b: CellTile) => a.offset - b.offset);
  return { n, x: Float32Array.from(cols.x), y: Float32Array.from(cols.y), tiles, url };
}

// Cell IDs are only needed for tooltips; read them on first use.
let ids: ArrayLike<string> | null = null;
let idsLoading: Promise<void> | null = null;
export function cellId(cells: Cells, i: number, onLoaded?: () => void): string | undefined {
  if (ids) return ids[i];
  if (!idsLoading) {
    idsLoading = rangeBuffer(cells.url)
      .then(f => readColumns(f, ['cell_ID']))
      .then(c => { ids = c.cell_ID ?? []; })
      .catch(e => console.warn('GiottoLens: could not read cell IDs', e));
  }
  if (onLoaded) idsLoading.then(onLoaded);
  return undefined;
}

// Tiles whose centroid bounds intersect a box, for pruning cell scans
export function tilesInBox(cells: Cells, xmin: number, xmax: number, ymin: number, ymax: number): CellTile[] {
  return cells.tiles.filter(t => t.n > 0 &&
    t.bounds[1] >= xmin && t.bounds[0] <= xmax && t.bounds[3] >= ymin && t.bounds[2] <= ymax);
}
