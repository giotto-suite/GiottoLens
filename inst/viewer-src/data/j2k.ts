// JPEG-2000 tiles (TIFF compression 34712, as in Xenium morphology files),
// decoded with OpenJPEG compiled to WASM. geotiff has no decoder for them;
// img-worker.ts registers this one with geotiff in each image worker.
import openjpeg from '@cornerstonejs/codec-openjpeg/decodewasmjs';

export interface J2KFrame {
  data: ArrayBuffer;        // pixels, row-major, one component
  width: number;
  height: number;
  bitsPerSample: number;
}

// `init`: emscripten module options, e.g. { locateFile } in a browser worker
// or { wasmBinary } under node
let _codec: Promise<any> | null = null;
export function initJ2K(init: Record<string, unknown> = {}) {
  // OpenJPEG logs every tile header; keep the console for real errors
  _codec ??= openjpeg({ print: () => {}, printErr: () => {}, ...init });
  return _codec;
}

export async function decodeJ2K(bytes: Uint8Array): Promise<J2KFrame> {
  const codec = await initJ2K();
  const dec = new codec.J2KDecoder();
  try {
    dec.getEncodedBuffer(bytes.length).set(bytes);
    dec.decode();
    const info = dec.getFrameInfo();
    if (info.componentCount !== 1)
      throw new Error(`JPEG-2000 tile has ${info.componentCount} components; only 1 is supported`);
    // The decoded buffer is a view into WASM memory: copy it out
    const data = dec.getDecodedBuffer().slice().buffer as ArrayBuffer;
    return { data, width: info.width, height: info.height, bitsPerSample: info.bitsPerSample };
  } finally {
    dec.delete();
  }
}
