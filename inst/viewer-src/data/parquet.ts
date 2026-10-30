// Parquet over HTTP: Range reads with hyparquet, and columnar decoding. The browser
// reads parquet R prepared and keeps no SQL model of its own (adr/0003).
import { parquetRead, parquetMetadataAsync } from 'hyparquet';
// @ts-ignore: not in hyparquet's type exports
import { DEFAULT_PARSERS } from 'hyparquet/src/convert.js';

export interface AsyncBuffer {
  byteLength: number;
  slice(start: number, end?: number): Promise<ArrayBuffer> | ArrayBuffer;
}

// ── Request limiter ───────────────────────────────────────────────────────────
// At most MAX_INFLIGHT Range requests at once across all files. hyparquet asks
// for every column chunk of a file together, and many tiles of row groups ×
// columns otherwise exhaust the browser's connection pool
// (ERR_INSUFFICIENT_RESOURCES). First come, first served, so tiles requested
// first (nearest the view centre) finish first. A load aborted while queued
// leaves the queue and never starts.
const MAX_INFLIGHT = 6;
let inflight = 0;
const waiting: (() => void)[] = [];
async function acquire(signal?: AbortSignal): Promise<void> {
  signal?.throwIfAborted();
  if (inflight < MAX_INFLIGHT) { inflight++; return; }
  await new Promise<void>((resolve, reject) => {
    const wake = () => { signal?.removeEventListener('abort', drop); resolve(); };
    const drop = () => {
      const i = waiting.indexOf(wake);
      if (i >= 0) waiting.splice(i, 1);
      reject(signal!.reason);
    };
    waiting.push(wake);
    signal?.addEventListener('abort', drop, { once: true });
  });
}
function release(): void {
  const next = waiting.shift();
  if (next) next(); else inflight--;   // hand the slot straight to a waiter
}

// The manifest records each file's size, so no probe is needed. Without it,
// probe with bytes=0-0, which every Range server answers with
// Content-Range: bytes 0-0/<total>.
async function probeSize(url: string, signal?: AbortSignal): Promise<{ byteLength?: number; full?: ArrayBuffer }> {
  const probe = await fetch(url, { headers: { Range: 'bytes=0-0' }, signal });
  if (probe.status === 206) {
    await probe.body?.cancel();
    const total = parseInt((probe.headers.get('content-range') ?? '').split('/')[1]);
    if (total > 0) return { byteLength: total };
  }
  if (!probe.ok) throw new Error(`${url}: HTTP ${probe.status}`);
  return { full: await probe.arrayBuffer() };
}

export async function rangeBuffer(url: string, byteLength?: number, signal?: AbortSignal): Promise<AsyncBuffer> {
  if (!byteLength) {
    const p = await probeSize(url, signal);
    // No Range support: degrade to one full download rather than fail
    if (p.full) {
      const full = p.full;
      return { byteLength: full.byteLength, slice: (s, e) => full.slice(s, e) };
    }
    byteLength = p.byteLength!;
  }
  const size = byteLength;
  return {
    byteLength: size,
    slice: async (start, end) => {
      await acquire(signal);
      try {
        const r = await fetch(url, { headers: { Range: `bytes=${start}-${(end ?? size) - 1}` }, signal });
        // A 200 here is the whole file, which would be read as the slice
        if (r.status !== 206) throw new Error(`${url}: Range request answered with ${r.status}, not 206`);
        return await r.arrayBuffer();
      } finally {
        release();
      }
    },
  };
}

// ── Codecs ───────────────────────────────────────────────────────────────────
// hyparquet decodes only SNAPPY itself. GiottoDisk writes SNAPPY by default,
// but its codec is an option, and its Xenium zarr converter writes ZSTD; arrow
// writes "lz4" as LZ4_RAW. hyparquet-compressors covers ZSTD, GZIP, LZ4_RAW
// and Hadoop-framed LZ4 (any number of frames), and its WASM SNAPPY is 2.6x
// faster than hyparquet's JS one on Atera tiles. BROTLI is left out: R's arrow
// cannot write it, and its decoder (with its dictionary) is most of the
// package's size.
import { decompressZstd, decompressLz4, decompressLz4Raw, gunzip } from 'hyparquet-compressors';
// @ts-ignore: no type exports
import { snappyUncompressor } from 'hysnappy';
export const compressors = {
  SNAPPY: snappyUncompressor(),
  GZIP: (input: Uint8Array, length: number) => gunzip(input, new Uint8Array(length)),
  ZSTD: (input: Uint8Array) => decompressZstd(input),
  LZ4: decompressLz4,
  LZ4_RAW: decompressLz4Raw,
};

// Geometry columns stay WKB bytes; data/wkb.ts decodes them into flat arrays
// instead of hyparquet building GeoJSON objects.
const PARSERS = { ...DEFAULT_PARSERS, geometryFromBytes: (b: Uint8Array) => b, geographyFromBytes: (b: Uint8Array) => b };

// Read columns as arrays (one per column, row groups concatenated). Columns
// missing from the file are absent from the result; `null` reads them all.
export async function readColumns(file: AsyncBuffer | ArrayBuffer, columns: string[] | null, metadata?: any): Promise<Record<string, ArrayLike<any>>> {
  metadata ??= await parquetMetadataAsync(file as any, { parsers: PARSERS } as any);
  const leaves = metadata.schema.slice(1).filter((e: any) => !e.num_children).map((e: any) => e.name as string);
  const cols = columns ? columns.filter(c => leaves.includes(c)) : leaves;
  const chunks: Record<string, { start: number; data: ArrayLike<any> }[]> = {};
  for (const c of cols) chunks[c] = [];
  await parquetRead({
    file: file as any, metadata, columns: cols, compressors, parsers: PARSERS,
    onChunk: ({ columnName, columnData, rowStart }: any) => chunks[columnName].push({ start: rowStart, data: columnData }),
  } as any);
  const out: Record<string, ArrayLike<any>> = {};
  for (const c of cols) {
    const parts = chunks[c].sort((a, b) => a.start - b.start);
    out[c] = parts.length === 1 ? parts[0].data : parts.flatMap(p => Array.from(p.data));
  }
  return out;
}

// ── Tile reads: whole file or merged column ranges ───────────────────────────
// Parquet stores each column of each row group as its own block, so reading a
// few columns means one range per column per row group. Two ways to read a
// tile:
//   'whole'   — one request for the whole file, served by httpuv's own thread
//               (no R involved). Best when the browser is on the same machine
//               as R: bytes are free, round trips through R are not.
//   'columns' — the drawn columns' blocks, with blocks less than MERGE_GAP
//               apart merged into one request. Best on slow links.
// 'auto' starts with 'whole' on a localhost URL and switches to 'columns' when
// whole tiles arrive slowly: an SSH port forward also looks like localhost
// (adr/0004).

export type Transfer = 'auto' | 'whole' | 'columns';
const MERGE_GAP = 1 << 20;          // merge blocks less than 1 MB apart
const SLOW_MBPS = 150;              // below this, a whole-file fetch counts as slow
const LOOPBACK = ['localhost', '127.0.0.1', '[::1]', '::1'];

let transfer: Transfer = 'auto';
let autoMode: 'whole' | 'columns' | null = null;
let slowCount = 0;

export function setTransfer(t: Transfer): void { transfer = t; autoMode = null; slowCount = 0; }
export function transferMode(): 'whole' | 'columns' {
  if (transfer !== 'auto') return transfer;
  return autoMode ?? (LOOPBACK.includes((globalThis as any).location?.hostname ?? '') ? 'whole' : 'columns');
}

async function fetchWhole(url: string, signal?: AbortSignal): Promise<ArrayBuffer> {
  await acquire(signal);
  try {
    const t0 = performance.now();
    const r = await fetch(url, { signal });
    if (!r.ok) throw new Error(`${url}: HTTP ${r.status}`);
    const ab = await r.arrayBuffer();
    const mbps = ab.byteLength / 1e6 / ((performance.now() - t0) / 1000);
    if (transfer === 'auto' && ab.byteLength > 2e6) {
      slowCount = mbps < SLOW_MBPS ? slowCount + 1 : 0;
      if (slowCount >= 2) autoMode = 'columns';
    }
    return ab;
  } finally {
    release();
  }
}

// Byte ranges of the given columns' blocks, merged when close together
export function mergedRanges(metadata: any, columns: string[], gap = MERGE_GAP): [number, number][] {
  const ranges: [number, number][] = [];
  for (const rg of metadata.row_groups) {
    for (const chunk of rg.columns) {
      const m = chunk.meta_data;
      if (!m || !columns.includes(m.path_in_schema[0])) continue;
      // same arithmetic as hyparquet's read plan, so its reads fall inside
      const start = Number(m.dictionary_page_offset || m.data_page_offset);
      ranges.push([start, start + Number(m.total_compressed_size)]);
    }
  }
  ranges.sort((a, b) => a[0] - b[0]);
  const out: [number, number][] = [];
  for (const r of ranges) {
    const last = out[out.length - 1];
    if (last && r[0] - last[1] <= gap) last[1] = Math.max(last[1], r[1]);
    else out.push([r[0], r[1]]);
  }
  return out;
}

// A tile's bytes for the given columns, fetched per the transfer mode, plus
// its parquet metadata. `file.slice()` then serves the columns' blocks from
// memory. `signal` aborts the tile's requests, queued or in flight.
export async function tileSource(tile: { url: string; file?: string; bytes?: number }, columns: string[],
    signal?: AbortSignal): Promise<{ file: AsyncBuffer; metadata: any }> {
  if (tile.file && transferMode() === 'whole') {
    const ab = await fetchWhole(tile.file, signal);
    const metadata = await parquetMetadataAsync(ab as any, { parsers: PARSERS } as any);
    return { file: { byteLength: ab.byteLength, slice: (s, e) => ab.slice(s, e) }, metadata };
  }
  const file = await rangeBuffer(tile.url, tile.bytes, signal);
  // Footers here are a few tens of KB; hyparquet's default first read is 512 KB
  const metadata = await parquetMetadataAsync(file as any, { parsers: PARSERS, initialFetchSize: 1 << 16 } as any);
  const ranges = mergedRanges(metadata, columns);
  const parts = ranges.map(([a, b]) => Promise.resolve(file.slice(a, b)));
  // A part the decoder never reaches (it failed or was aborted first) must not
  // surface as an unhandled rejection
  for (const p of parts) p.catch(() => {});
  return {
    metadata,
    file: {
      byteLength: file.byteLength,
      slice(start, end = file.byteLength) {
        const i = ranges.findIndex(([a, b]) => a <= start && end <= b);
        if (i < 0) return file.slice(start, end);
        const a = ranges[i][0];
        return parts[i].then(buf => buf.slice(start - a, end - a));
      },
    },
  };
}

export async function readTileColumns(tile: { url: string; file?: string; bytes?: number }, columns: string[],
    signal?: AbortSignal) {
  const { file, metadata } = await tileSource(tile, columns, signal);
  return readColumns(file, columns, metadata);
}

export function numRows(cols: Record<string, ArrayLike<any>>): number {
  for (const v of Object.values(cols)) return v.length;
  return 0;
}
