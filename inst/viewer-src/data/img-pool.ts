// Image tile decoders in workers, in the shape geotiff expects of a pool
// (`decode(fileDirectory, buffer)`). Unlike geotiff's own Pool, a failed
// decode rejects instead of leaving its tile waiting forever, and requests
// go to the least busy worker.
export class ImagePool {
  private workers: (Worker & { busy: number })[];
  private pending = new Map<number, { resolve: (b: ArrayBuffer) => void; reject: (e: Error) => void }>();
  private seq = 0;

  constructor(size = Math.max(1, Math.min(4, Math.floor((navigator.hardwareConcurrency || 4) / 2)))) {
    this.workers = Array.from({ length: size }, () => {
      const w = new Worker(new URL('./img-worker.ts', import.meta.url), { type: 'module' }) as Worker & { busy: number };
      w.busy = 0;
      w.onmessage = ({ data }) => {
        const p = this.pending.get(data.id);
        if (!p) return;
        this.pending.delete(data.id);
        w.busy--;
        if (data.error) p.reject(new Error(data.error));
        else p.resolve(data.decoded);
      };
      return w;
    });
  }

  decode(fileDirectory: Record<string, unknown>, buffer: ArrayBuffer): Promise<ArrayBuffer> {
    const w = this.workers.reduce((a, b) => (b.busy < a.busy ? b : a));
    const id = ++this.seq;
    w.busy++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      w.postMessage({ id, fileDirectory, buffer }, [buffer]);
    });
  }

  destroy() {
    for (const w of this.workers) w.terminate();
    this.workers = [];
  }
}
