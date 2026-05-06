// Shared mutable state — all modules import from here.
// Using a plain object so any module can update state.foo = bar
// and all other importers see the change via the same reference.

export const state = {
  // DuckDB connections
  db: null, conn: null, overviewConn: null, polyConn: null,
  spatialLoaded: false,

  // App
  manifest: null, deckgl: null, tileTimer: null,
  geneIndex: null, currentViewState: null,

  // Tile management
  cache:     new Map(),   // "layer:idx" → data
  pending:   new Set(),
  cancelled: new Set(),
  failed:    new Set(),   // transcript tiles that errored — no retry

  // Gene selection
  selectedGenes:    new Set(),
  geneOverviewCache: new Map(),
  colorAll:   false,
  searchTerm: '',

  // Overview
  overviewBins:         null,
  overviewGeneKey:      null,
  manifestOverviewBins: null,

  // Visibility + opacity
  showOverview: true,  alphaOverview: 0.80,
  showPoly:     true,  alphaPoly:     0.60,
  showTx:       false, alphaTx:       0.70,

  // Data caches
  txBuild:   null, txDirty:   true,
  polyBuild: null, polyDirty: true,

  // Annotation / selection
  mode:         'pan',   // 'pan' | 'draw' | 'lasso'
  drawRing:     [],
  lassoRing:    [],
  lassoActive:  false,
  selectedCells: new Set(),
  selVersion:   0,

  // Cell metadata
  metaCols:    [],    // [{name, numeric}] populated when metadata is loaded
  metaCol:     null,  // active coloring column
  metaColors:  null,  // Map<cell_ID, [r,g,b,a]> built async
};
