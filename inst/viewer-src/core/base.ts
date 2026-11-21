// The data (manifest, tiles, metadata, images) is served under d/<secret>/ of
// the page's URL. R sends the secret over the WebSocket to the one window it
// gives the viewer (core/comms.js, adr/0028).
let root = '';

export function setDataRoot(secret: string): void { root = `d/${secret}/`; }
export const dataRoot = (): string => root;

// The absolute URL of data path `rel` ('session/manifest.json', a tile's url)
export function dataUrl(rel: string): string {
  return new URL(root + rel, document.baseURI).href;
}
