// A small pool of transcript-decoding workers. Requests go to the least busy
// worker; each worker keeps its own Range-request limit.
import { state } from '../core/state.js';
import { decodeTranscriptTile } from './tx-decode.ts';

let _pool = null;
let _seq = 0;
const _pending = new Map();   // id → { resolve, reject, worker }

function pool() {
  if (_pool || typeof Worker === 'undefined') return _pool;
  const n = Math.max(1, Math.min(4, Math.floor((navigator.hardwareConcurrency || 4) / 2)));
  const genes = state.manifest?.layers?.transcripts?.genes ?? [];
  _pool = Array.from({ length: n }, () => {
    const w = new Worker(new URL('./tx-worker.ts', import.meta.url), { type: 'module' });
    w.busy = 0;
    w.onmessage = ({ data }) => {
      const p = _pending.get(data.id);
      if (!p) return;
      _pending.delete(data.id);
      w.busy--;
      if (data.error) p.reject(new Error(data.error));
      else p.resolve({ pos: data.pos, geneIdxs: data.geneIdxs, stride: p.stride });
    };
    w.postMessage({ type: 'init', genes, transfer: state.manifest?.transfer ?? 'auto' });
    return w;
  });
  return _pool;
}

// tile: { url, file, bytes } from the manifest; stride: keep every n-th point
export function fetchTranscriptTile(tile, stride = 1) {
  const workers = pool();
  if (!workers) return decodeTranscriptTile(tile, state.geneIndex, stride).then(d => ({ ...d, stride }));
  const w = workers.reduce((a, b) => (b.busy < a.busy ? b : a));
  const id = ++_seq;
  w.busy++;
  return new Promise((resolve, reject) => {
    _pending.set(id, { resolve, reject, stride });
    w.postMessage({ id, stride, tile: { url: tile.url, file: tile.file, bytes: tile.bytes } });
  });
}
