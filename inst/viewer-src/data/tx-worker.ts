// Fetches and decodes transcript tiles off the main thread, so panning stays
// smooth while tiles arrive. Arrays are transferred back, not copied.
// An 'abort' message stops a request's fetch and decode; it replies nothing.
import { decodeTranscriptTile } from './tx-decode.ts';
import { setTransfer } from './parquet.ts';

let geneIndex = new Map<string, number>();
const loads = new Map<number, AbortController>();   // request id → its controller

self.onmessage = async (e: MessageEvent) => {
  const msg = e.data;
  if (msg.type === 'init') {
    geneIndex = new Map((msg.genes as string[]).map((g, i) => [g, i]));
    setTransfer(msg.transfer ?? 'auto');
    return;
  }
  if (msg.type === 'abort') {
    loads.get(msg.id)?.abort();
    return;
  }
  const ctl = new AbortController();
  loads.set(msg.id, ctl);
  try {
    const { pos, geneIdxs } = await decodeTranscriptTile(msg.tile, geneIndex, msg.stride ?? 1, ctl.signal);
    if (!ctl.signal.aborted)
      (self as any).postMessage({ id: msg.id, pos, geneIdxs }, [pos.buffer, geneIdxs.buffer]);
  } catch (err) {
    if (!ctl.signal.aborted)
      (self as any).postMessage({ id: msg.id, error: String((err as Error)?.message ?? err) });
  } finally {
    loads.delete(msg.id);
  }
};
