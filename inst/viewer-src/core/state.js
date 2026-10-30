// Runtime state: handles, loaded data, caches and in-progress drawing. Never
// saved. Savable settings (layers, colouring, selection rules, annotations,
// tool settings) live in the store (core/store.ts).

/** @type {Record<string, any>} */
export const state = {
  // App
  manifest: null, deckgl: null, tileTimer: null, currentViewState: null,
  geneIndex: null,          // Map gene name → index into manifest genes

  // Cells (data/cells.ts) and metadata (data/meta.ts)
  cells: null,              // { n, x, y, tiles, url }
  cellPositions: null,      // Float32Array x0,y0,x1,y1,… for deck.gl
  meta: null,               // Map column → MetaColumn
  cellColors: null,         // Uint8Array RGBA per cell for the colour-by column
  colorLegend: null,
  selPositions: null,       // Float32Array of selected cell centroids

  // Tiles
  cache:     new Map(),     // "layer:idx" → decoded tile
  pending:   new Map(),     // "layer:idx" → AbortController of the load in flight
  failed:    new Map(),     // transcript tile → time it failed (retried later)

  // Transcript zoom tier (stride sampling), see data/tiles.js txDrawTiles()
  txZoomTier: -1,

  // In-progress drawing and measuring
  drawRing:     [],
  lassoRing:    [],
  lassoActive:  false,
  rectStart:    null,
  rectPreview:  null,
  rulerStart:   null,
  rulerEnd:     null,
  rulerLocked:  false,
  txLassoRing:  null,
  brushDown:    false,
  brushPos:     null,
};
