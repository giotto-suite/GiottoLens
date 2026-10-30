// Cell metadata pushed from R, one typed array per column in cell order.
// Categorical columns arrive as 0-based codes (-1 = NA) plus levels.
import { rangeBuffer, readColumns } from './parquet.ts';

export interface MetaColumn {
  name: string;
  kind: 'categorical' | 'continuous';
  levels?: string[];
  values: Int32Array | Float64Array;   // codes or numbers (NaN = NA)
  min: number;
  max: number;
}

export type Meta = Map<string, MetaColumn>;

export async function loadMeta(url: string, columns: { name: string; kind: string; levels?: string[] }[]): Promise<Meta> {
  const file = await rangeBuffer(new URL(url, document.baseURI).href);
  const data = await readColumns(file, columns.map(c => c.name));
  const out: Meta = new Map();
  for (const c of columns) {
    const raw = data[c.name];
    if (!raw) continue;
    const cat = c.kind === 'categorical';
    const values = cat ? new Int32Array(raw.length) : new Float64Array(raw.length);
    let min = Infinity, max = -Infinity;
    for (let i = 0; i < raw.length; i++) {
      const v = raw[i];
      const x = v == null ? (cat ? -1 : NaN) : Number(v);
      values[i] = x;
      if (!cat && x === x) { if (x < min) min = x; if (x > max) max = x; }
    }
    out.set(c.name, { name: c.name, kind: cat ? 'categorical' : 'continuous', levels: c.levels, values, min, max });
  }
  return out;
}

// Display value of one cell
export function metaValue(col: MetaColumn, i: number): string | number | null {
  const v = col.values[i];
  if (col.kind === 'categorical') return v < 0 ? null : col.levels?.[v] ?? String(v);
  return v === v ? v : null;
}
