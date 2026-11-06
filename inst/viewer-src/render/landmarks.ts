// Landmark pairs of the image being registered, for one of the two panes:
// 'moving' (the image's own pane, in its orientation) or 'fixed' (the main
// view, data coordinates). A pane's own points are filled and can be dragged;
// with a fit, the other pane's points are drawn hollow where the fit puts
// them, joined to their partner, and each pair is numbered.
import { ScatterplotLayer, LineLayer, TextLayer } from 'deck.gl';
import { apply, compose, invert, registrationFit, type Registration, type XY, type Affine } from '../data/registration.ts';

export type Side = 'moving' | 'fixed';
export const MOVING_COLOR: [number, number, number] = [255, 80, 200];
export const FIXED_COLOR: [number, number, number] = [80, 220, 255];

export interface LandmarkPoint { id: string; n: number; which: Side; pos: XY }

// A point being dragged: drawn at `pos` (its pane's coordinates) until dropped
export interface LandmarkDrag { id: string; which: Side; pos: XY }

// Where each side's points go in `side`'s pane; null when there is no fit
export function paneMaps(reg: Registration, side: Side): Record<Side, Affine | null> {
  const fit = registrationFit(reg)?.transform ?? null;
  if (side === 'fixed') return { fixed: [1, 0, 0, 0, 1, 0], moving: fit };
  const inv = fit && invert(fit);
  return { moving: reg.orient, fixed: inv ? compose(reg.orient, inv) : null };
}

export function landmarkPoints(reg: Registration, side: Side, drag: LandmarkDrag | null = null) {
  const maps = paneMaps(reg, side);
  const own: LandmarkPoint[] = [], other: LandmarkPoint[] = [];
  const links: { from: XY; to: XY }[] = [];
  reg.landmarks.forEach((l, i) => {
    let mine: XY | null = null, theirs: XY | null = null;
    for (const which of ['moving', 'fixed'] as const) {
      const p = l[which], m = maps[which];
      if (!p || !m) continue;
      const pos = drag && which === side && drag.id === l.id && drag.which === which ? drag.pos : apply(m, p);
      (which === side ? own : other).push({ id: l.id, n: i + 1, which, pos });
      if (which === side) mine = pos; else theirs = pos;
    }
    if (mine && theirs) links.push({ from: mine, to: theirs });
  });
  return { own, other, links };
}

const colorOf = (w: Side) => w === 'moving' ? MOVING_COLOR : FIXED_COLOR;

export function landmarkLayers(reg: Registration, side: Side, drag: LandmarkDrag | null,
                               onHover?: (info: any) => void) {
  const { own, other, links } = landmarkPoints(reg, side, drag);
  return [
    new LineLayer<{ from: XY; to: XY }>({
      id: `lm-${side}-links`, data: links,
      getSourcePosition: d => d.from, getTargetPosition: d => d.to,
      getColor: [255, 230, 120, 220], getWidth: 1.5, widthUnits: 'pixels',
    }),
    new ScatterplotLayer<LandmarkPoint>({
      id: `lm-${side}-other`, data: other, getPosition: d => d.pos,
      getLineColor: d => [...colorOf(d.which), 200], stroked: true, filled: false,
      getLineWidth: 1.5, lineWidthUnits: 'pixels', getRadius: 5, radiusUnits: 'pixels',
    }),
    new ScatterplotLayer<LandmarkPoint>({
      id: `lm-${side}-points`, data: own, getPosition: d => d.pos,
      getFillColor: d => [...colorOf(d.which), 90], getLineColor: d => [...colorOf(d.which), 255],
      stroked: true, filled: true, getLineWidth: 2, lineWidthUnits: 'pixels',
      getRadius: 6, radiusUnits: 'pixels', pickable: true, onHover,
    }),
    new TextLayer<LandmarkPoint>({
      id: `lm-${side}-labels`, data: own, getPosition: d => d.pos, getText: d => String(d.n),
      getColor: d => [...colorOf(d.which), 255], getSize: 12, sizeUnits: 'pixels',
      getPixelOffset: [10, -10], fontFamily: 'monospace',
      outlineWidth: 2, outlineColor: [0, 0, 0, 255], fontSettings: { sdf: true },
    }),
  ];
}
