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
  colorAll:      false,
  txPaletteIdx:  0,
  searchTerm:    '',

  // Overview
  overviewBins:         null,
  overviewGeneKey:      null,
  manifestOverviewBins: null,

  // Visibility + opacity
  showOverview:     true,  alphaOverview:     0.80,
  showPoly:         true,  alphaPoly:         0.60,
  showTx:           false, alphaTx:           0.70,
  showAnnotations:  true,  alphaAnnotations:  0.60,

  // Annotations
  annotations:      [],
  selectedAnnotId:  null,
  onAnnotSelect:    null,
  onAnnotsChange:   null,

  // Data caches
  txBuild:    null, txDirty:    true,
  txZoomTier: -1,
  polyBuild:  null, polyDirty:  true,

  // Annotation / selection
  mode:         'pan',   // 'pan' | 'draw' | 'lasso' | 'rect'
  drawRing:     [],
  lassoRing:    [],
  lassoActive:  false,
  rectStart:    null,
  rectPreview:  null,
  rulerStart:   null,
  rulerEnd:     null,
  rulerLocked:  false,
  brushDown:    false,
  brushPos:     null,
  brushRadius:  30,
  selectedCells: new Set(),
  selVersion:   0,
  allPolyIds:   new Set(),

  // Cell metadata
  metaCols:    [],    // [{name, numeric}] populated when metadata is loaded
  metaCol:     null,  // active coloring column
  metaColors:  null,  // Map<cell_ID, [r,g,b,a]> built async
  metaLegend:  null,  // {type:'categorical',items:[{label,color}]} | {type:'continuous',min,max}
};
