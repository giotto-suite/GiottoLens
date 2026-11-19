export const TRANSCRIPT_ZOOM_THRESHOLD = 0;
export const POLYGON_ZOOM_THRESHOLD   = -1;  // outlines pop in; centroids show below
export const MAX_TRANSCRIPT_TILES     = 25;
export const MAX_LIST_ROWS            = 200;

export const PALETTE = [
  [76,114,176],[221,132,82],[85,168,104],[196,78,82],[129,114,179],
  [100,194,188],[218,139,195],[204,185,116],[140,140,140],[147,120,96],
  [255,157,166],[158,218,229],[152,223,138],[255,152,150],[197,176,213],
  [196,156,148],[247,182,210],[199,199,199],[219,219,141],[100,181,205],
];

export const PALETTE_VIVID = [
  [255,50,50],[255,140,0],[255,220,0],[100,220,0],[0,200,80],
  [0,220,180],[0,180,255],[0,80,255],[130,0,255],[220,0,255],
  [255,0,180],[255,80,120],[255,170,80],[180,255,80],[80,255,180],
  [80,200,255],[200,120,255],[255,120,200],[50,230,120],[255,200,50],
];

export const PALETTES = [PALETTE, PALETTE_VIVID];
// Okabe & Ito's colors, distinct for most color vision deficiencies
export const PALETTE_OKABE_ITO = [
  [230,159,0],[86,180,233],[0,158,115],[240,228,66],[0,114,178],
  [213,94,0],[204,121,167],[153,153,153],[0,0,0],[136,204,238],
];
// Category palettes by preference name (core/prefs.ts `cat_palette`)
export const CATEGORY_PALETTES = { default: PALETTE, vivid: PALETTE_VIVID, okabe_ito: PALETTE_OKABE_ITO };
