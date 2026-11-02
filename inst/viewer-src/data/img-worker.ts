// Decodes image tiles off the main thread for img-pool.ts: geotiff's own
// decoders plus JPEG-2000 (j2k.ts). geotiff's built-in worker pool has a
// fixed decoder set, so registering a decoder on the main thread would not
// reach it.
import { addDecoder, getDecoder, BaseDecoder } from 'geotiff';
import wasmUrl from '@cornerstonejs/codec-openjpeg/decodewasm?url';
import { initJ2K, decodeJ2K } from './j2k.ts';

initJ2K({ locateFile: () => wasmUrl });

class J2KDecoder extends BaseDecoder {
  async decodeBlock(buffer: ArrayBuffer) {
    return (await decodeJ2K(new Uint8Array(buffer))).data;
  }
}
addDecoder(34712, () => J2KDecoder);

self.onmessage = async (e: MessageEvent) => {
  const { id, fileDirectory, buffer } = e.data;
  try {
    const decoder = await getDecoder(fileDirectory);
    const decoded: ArrayBuffer = await decoder.decode(fileDirectory, buffer);
    (self as any).postMessage({ id, decoded }, [decoded]);
  } catch (err) {
    (self as any).postMessage({ id, error: String((err as Error)?.message ?? err) });
  }
};
