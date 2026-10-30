import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'credentialless',
    },
    // Dev against a running viewer: launch_lens(..., port = 3000), then open
    // the Vite page with the same ?token= as the viewer URL R printed
    proxy: {
      '/lens/session': 'http://127.0.0.1:3000',
      '/lens/data':    'http://127.0.0.1:3000',
      '/lens/ws':      { target: 'ws://127.0.0.1:3000', ws: true },
    },
  },
  base: '/lens/',
  build: {
    outDir:      '../viewer',
    emptyOutDir: true,
    target:      'esnext',
  },
});
