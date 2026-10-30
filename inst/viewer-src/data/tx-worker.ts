// Fetches and decodes transcript tiles off the main thread, so panning stays
// smooth while tiles arrive. Arrays are transferred back, not copied.
import { decodeTranscriptTile } from './tx-decode.ts';
import { setTransfer } from './parquet.ts';

let geneIndex = new Map<string, number>();

self.onmessage = async (e: MessageEvent) => {
  const msg = e.data;
  if (msg.type === 'init') {
    geneIndex = new Map((msg.genes as string[]).map((g, i) => [g, i]));
    setTransfer(msg.transfer ?? 'auto');
    return;
  }
  try {
    const { pos, geneIdxs } = await decodeTranscriptTile(msg.tile, geneIndex, msg.stride ?? 1);
    (self as any).postMessage({ id: msg.id, pos, geneIdxs }, [pos.buffer, geneIdxs.buffer]);
  } catch (err) {
    (self as any).postMessage({ id: msg.id, error: String((err as Error)?.message ?? err) });
  }
};
