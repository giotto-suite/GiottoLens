import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    headers: {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'credentialless',
    },
    // Dev against a running viewer: launch_lens(..., port = 3000), then open
    // the Vite page at the /lens/<token>/ path of the URL R printed
    proxy: {
      '^/lens/[^/]+/(session|data|files)/': 'http://127.0.0.1:3000',
      '^/lens/[^/]+/ws': { target: 'ws://127.0.0.1:3000', ws: true },
    },
  },
  // Relative asset URLs: the page is served under /lens/<token>/
  base: './',
  build: {
    outDir:      '../viewer',
    emptyOutDir: true,
    target:      'esnext',
  },
});
