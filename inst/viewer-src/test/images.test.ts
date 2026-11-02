import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { initJ2K, decodeJ2K } from '../data/j2k.ts';
import { defaultContrast, imageKind, layoutProblem } from '../data/images.ts';

const require = createRequire(import.meta.url);
initJ2K({ wasmBinary: readFileSync(require.resolve('@cornerstonejs/codec-openjpeg/decodewasm')) });

describe('JPEG-2000 tiles', () => {
  it('decode exactly (a lossless 16-bit codestream written by GDAL)', async () => {
    const bytes = new Uint8Array(readFileSync(new URL('./fixtures/gradient-200x120.j2k', import.meta.url)));
    const f = await decodeJ2K(bytes);
    expect([f.width, f.height, f.bitsPerSample]).toEqual([200, 120, 16]);
    const px = new Uint16Array(f.data);
    // The pattern R wrote, row by row
    let wrong = 0;
    for (let y = 0; y < 120; y++)
      for (let x = 0; x < 200; x++)
        if (px[y * 200 + x] !== (x * 7 + y * 13) % 4096 + (x >= 100 && y < 40 ? 30000 : 0)) wrong++;
    expect(wrong).toBe(0);
  });

  it('reject what is not a codestream', async () => {
    await expect(decodeJ2K(new Uint8Array(64))).rejects.toThrow();
  });
});

describe('default contrast', () => {
  it('spans the nonzero pixels, ignoring empty slide', () => {
    const data = new Uint16Array(10000);
    for (let i = 5000; i < 10000; i++) data[i] = 100 + (i % 1000);
    const { contrast, domain } = defaultContrast(data, 'Uint16');
    expect(contrast[0]).toBeGreaterThanOrEqual(100);
    expect(contrast[0]).toBeLessThan(110);
    expect(contrast[1]).toBeGreaterThan(1090);
    expect(domain).toEqual([0, 2198]);
  });

  it('handles an empty image', () => {
    expect(defaultContrast(new Uint8Array(16), 'Uint8').contrast).toEqual([0, 1]);
  });
});

describe('image kind from TIFF tags', () => {
  const fd = (spp: number, bits: number, pi: number, fmt?: number) =>
    ({ SamplesPerPixel: spp, BitsPerSample: Array(spp).fill(bits), PhotometricInterpretation: pi, SampleFormat: fmt && [fmt] });
  it('takes 8-bit RGB and YCbCr (JPEG) with 3 or 4 samples as colour', () => {
    expect(imageKind(fd(3, 8, 2))).toBe('rgb');
    expect(imageKind(fd(3, 8, 6))).toBe('rgb');
    expect(imageKind(fd(4, 8, 2))).toBe('rgb');
  });
  it('takes one sample of a known type as a channel', () => {
    expect(imageKind(fd(1, 16, 1))).toBe('channel');
    expect(imageKind(fd(1, 8, 0))).toBe('channel');
    expect(imageKind(fd(1, 32, 1, 3))).toBe('channel');
  });
  it('says why it cannot show the rest', () => {
    expect(imageKind(fd(3, 16, 2))).toEqual({ error: '16-bit RGB is not supported; only 8-bit' });
    expect(imageKind(fd(3, 8, 1))).toHaveProperty('error', expect.stringMatching(/not RGB/));
    expect(imageKind(fd(1, 8, 3))).toHaveProperty('error', expect.stringMatching(/palette/));
    expect(imageKind(fd(1, 64, 1, 3))).toHaveProperty('error', expect.stringMatching(/64-bit/));
  });
});

describe('layouts that cannot be read by tile', () => {
  it('refuses large images in strips or without a pyramid', () => {
    expect(layoutProblem(46543, 28048, false, 1)).toMatch(/in strips, not tiles/);
    expect(layoutProblem(46543, 28048, true, 1)).toMatch(/without a pyramid/);
  });
  it('accepts pyramids, and small images whatever their layout', () => {
    expect(layoutProblem(46543, 28048, true, 8)).toBeNull();
    expect(layoutProblem(2000, 1500, false, 1)).toBeNull();
    expect(layoutProblem(4096, 4096, true, 1)).toBeNull();
  });
});
