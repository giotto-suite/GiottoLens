import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
    },
    proxy: {
      '/lens/manifest.json': 'http://localhost:3000',
      '/lens/metadata':      'http://localhost:3000',
      '/artifacts':          'http://localhost:3000',
    },
  },
  base: '/lens/',
  build: {
    outDir:      '../viewer',
    emptyOutDir: true,
    target:      'esnext',
  },
  optimizeDeps: {
    exclude: ['@duckdb/duckdb-wasm'],
  },
  assetsInclude: ['**/*.wasm'],
});
