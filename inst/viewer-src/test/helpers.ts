// Setup shared by several test files
import { vi } from 'vitest';
import fs from 'node:fs';
import type { MetaColumn, Meta } from '../data/meta.ts';
import type { Cells } from '../data/cells.ts';

// Waits out the current task
export const tick = () => new Promise(r => setTimeout(r, 0));

// Seeded LCG, so a test's random data is the same every run
export function rng(seed: number) {
  let s = seed;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
}

// A file in test/fixtures, as a view over the read buffer
export function fixtureBytes(f: string) {
  const buf = fs.readFileSync(new URL(`./fixtures/${f}`, import.meta.url));
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

// A file in test/fixtures, as an ArrayBuffer of its own
export function fixtureBuffer(f: string) {
  const b = fs.readFileSync(new URL(`./fixtures/${f}`, import.meta.url));
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
}

// A fetch that serves `bytes`, answering a Range header with a 206 slice
// (unless `range` is false: then always the whole file), and records calls
export function rangeServer(bytes: Uint8Array, { range = true } = {}) {
  const calls: { url: string; range?: string }[] = [];
  const f = vi.fn(async (url: string, opts: any = {}) => {
    const h = opts.headers?.Range;
    calls.push({ url, range: h });
    if (!h || !range) return new Response(bytes.slice(), { status: 200 });
    const [, a, b] = h.match(/bytes=(\d+)-(\d+)/);
    return new Response(bytes.slice(+a, +b + 1), { status: 206,
      headers: { 'content-range': `bytes ${a}-${b}/${bytes.length}` } });
  });
  return { f, calls };
}

// A continuous column over its non-NaN range
export function continuousColumn(name: string, v: Float64Array): MetaColumn {
  let min = Infinity, max = -Infinity;
  for (const x of v) if (x === x) { if (x < min) min = x; if (x > max) max = x; }
  return { name, kind: 'continuous', values: v, min, max };
}

// 10 x 10 grid of cells at (i + 0.5, j + 0.5), two tiles split at x = 5
export function grid(): Cells {
  const n = 100, x = new Float32Array(n), y = new Float32Array(n);
  let k = 0;
  for (const half of [0, 1]) for (let i = 0; i < 5; i++) for (let j = 0; j < 10; j++) {
    x[k] = half * 5 + i + 0.5; y[k] = j + 0.5; k++;
  }
  return { n, x, y, url: '', tiles: [
    { index: 1, offset: 0, n: 50, bounds: [0.5, 4.5, 0.5, 9.5] },
    { index: 2, offset: 50, n: 50, bounds: [5.5, 9.5, 0.5, 9.5] },
  ] };
}

// A continuous 'score' (= x) and a categorical 'lab' with NAs over `cells`
export function gridMeta(cells: Cells): Meta {
  const score = new Float64Array(cells.n), lab = new Int32Array(cells.n);
  for (let i = 0; i < cells.n; i++) { score[i] = cells.x[i]; lab[i] = i % 3 === 0 ? -1 : i % 2; }
  return new Map([
    ['score', { name: 'score', kind: 'continuous', values: score, min: 0.5, max: 9.5 }],
    ['lab', { name: 'lab', kind: 'categorical', levels: ['a', 'b'], values: lab, min: 0, max: 0 }],
  ]);
}
