// Cells drawn as marks when there is no polygon to draw (adr/0010). A circle
// is sized in data units with a pixel minimum, so it is a dot zoomed out and
// grows to its true size zoomed in. deck.gl's ColumnLayer, which draws the
// squares and hexagons, has no pixel minimum, so dots stand in for them until
// they are as wide as a dot.
import { ScatterplotLayer, ColumnLayer } from 'deck.gl';

export interface Mark {
  shape: 'circle' | 'square' | 'hex';
  size: number;     // across, in data units (a hexagon across its flats)
  angle: number;    // degrees
}

// Radius of a cell dot in pixels
export const DOT_PX = 2;

// Outlines with radius 1 for ColumnLayer `vertices`, scaled by `radius`
// (half the mark's size): a square of side 2, and a hexagon 2 across its flats
const SQUARE: [number, number][] = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
const HEX: [number, number][] = Array.from({ length: 6 }, (_, k) => {
  const a = Math.PI / 6 + k * Math.PI / 3;
  const r = 2 / Math.sqrt(3);
  return [r * Math.cos(a), r * Math.sin(a)];
});

// Whether the mark is drawn as its shape at this zoom rather than as a dot
export function showsShape(mark: Mark | undefined, zoom: number): boolean {
  if (!mark) return false;
  return mark.shape === 'circle' || mark.size * Math.pow(2, zoom) >= 2 * DOT_PX;
}

interface CellLayerOptions {
  mark?: Mark;
  zoom: number;
  data: unknown;         // binary data: getPosition and getFillColor attributes
  opacity: number;
  onHover: (info: any) => void;
}

export function cellMarkLayer({ mark, zoom, data, opacity, onHover }: CellLayerOptions) {
  const common = { data: data as any, opacity, pickable: true, onHover };
  if (!showsShape(mark, zoom)) {
    return new ScatterplotLayer({ id: 'cell-centroids', ...common,
      getRadius: DOT_PX, radiusUnits: 'pixels', radiusMinPixels: 1 });
  }
  const m = mark as Mark;
  if (m.shape === 'circle') {
    return new ScatterplotLayer({ id: 'cell-circles', ...common,
      getRadius: m.size / 2, radiusUnits: 'common', radiusMinPixels: DOT_PX });
  }
  const vertices = m.shape === 'square' ? SQUARE : HEX;
  return new ColumnLayer({ id: m.shape === 'square' ? 'cell-squares' : 'cell-hexagons', ...common,
    vertices, diskResolution: vertices.length,
    radius: m.size / 2, radiusUnits: 'common', angle: m.angle,
    extruded: false, filled: true, stroked: false, material: false });
}
