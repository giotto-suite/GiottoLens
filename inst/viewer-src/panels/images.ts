// The images panel: per image, visibility, and for single-channel images
// colour and contrast (the pixel values drawn as black and as full colour, on
// one track with two thumbs). RGB images draw as they are.
import { state } from '../core/state.js';
import { store, actions, type ImageVis } from '../core/store.ts';
import type { PanelHandle } from './dock.ts';

type RGB = [number, number, number];
const hex = ([r, g, b]: number[]) => '#' + [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('');
const rgb = (h: string) => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)) as RGB;
const THUMB = 10;   // px, as in index.html

// One track, two thumbs that cannot pass each other: two range inputs
// stacked (keyboard and touch work as on any slider). `onChange([lo, hi])`.
function dualRange([min, max]: [number, number], step: number, onChange: (v: [number, number]) => void) {
  const el = Object.assign(document.createElement('div'), { className: 'range2' });
  const track = Object.assign(document.createElement('div'), { className: 'range2-track' });
  const fill = Object.assign(document.createElement('div'), { className: 'range2-fill' });
  const input = (title: string) => Object.assign(document.createElement('input'),
    { type: 'range', min: String(min), max: String(max), step: String(step), title });
  const lo = input('black at'), hi = input('full colour at');
  el.append(track, fill, lo, hi);

  const frac = (v: number) => (v - min) / (max - min || 1);
  const paint = () => {
    const a = frac(Number(lo.value)), b = frac(Number(hi.value));
    // A thumb's centre runs from THUMB/2 to width - THUMB/2
    fill.style.left  = `calc(${THUMB / 2}px + (100% - ${THUMB}px) * ${a})`;
    fill.style.width = `calc((100% - ${THUMB}px) * ${b - a})`;
    // Where the thumbs meet, the one that can still move away stays on top
    lo.style.zIndex = a > 0.5 ? '2' : '';
  };
  lo.addEventListener('input', () => {
    if (Number(lo.value) > Number(hi.value) - step) lo.value = String(Number(hi.value) - step);
    paint(); onChange([Number(lo.value), Number(hi.value)]);
  });
  hi.addEventListener('input', () => {
    if (Number(hi.value) < Number(lo.value) + step) hi.value = String(Number(lo.value) + step);
    paint(); onChange([Number(lo.value), Number(hi.value)]);
  });
  return {
    el,
    set([a, b]: number[], color: string) {
      // Values from R may lie outside the track; the thumbs stop at its ends
      lo.value = String(a); hi.value = String(b);
      fill.style.background = color;
      paint();
    },
  };
}

interface Row {
  item: HTMLElement; check: HTMLInputElement;
  color?: HTMLInputElement; range?: ReturnType<typeof dualRange>; val?: HTMLElement;
}

export function createImagesPanel(body: HTMLElement): PanelHandle {
  const list = Object.assign(document.createElement('div'), { className: 'ctl-body img-list' });
  body.append(list);
  const rows = new Map<string, Row>();

  for (const [name, img] of state.images) {
    const item = Object.assign(document.createElement('div'), { className: 'img-item' });
    const head = Object.assign(document.createElement('div'), { className: 'alpha-row' });
    const check = Object.assign(document.createElement('input'), { type: 'checkbox' });
    const label = Object.assign(document.createElement('span'), { className: 'img-name', textContent: name, title: name });
    check.addEventListener('change', () => actions.setImage(name, { show: check.checked }));
    item.append(head);
    list.appendChild(item);

    if (img.rgb) {
      head.append(check, label, Object.assign(document.createElement('span'), { className: 'img-tag', textContent: 'RGB' }));
      rows.set(name, { item, check });
      continue;
    }

    const color = Object.assign(document.createElement('input'), { type: 'color', className: 'img-color', title: 'colour' });
    color.addEventListener('input', () => actions.setImage(name, { color: rgb(color.value) }));
    head.append(check, color, label);

    const [d0, d1] = img.domain;
    const step = Number.isInteger(d0) && Number.isInteger(d1) && d1 - d0 > 100 ? 1 : (d1 - d0) / 1000;
    const range = dualRange(img.domain, step, contrast => actions.setImage(name, { contrast }));
    const val = document.createElement('span');
    const contrast = Object.assign(document.createElement('div'), { className: 'img-contrast' });
    contrast.append(range.el, val);
    item.append(contrast);
    rows.set(name, { item, check, color, range, val });
  }

  const sync = (images: Record<string, ImageVis>) => {
    for (const [name, r] of rows) {
      const v = images[name];
      if (!v) continue;
      r.check.checked = v.show;
      r.item.classList.toggle('item-off', !v.show);
      if (!r.range || !v.color || !v.contrast) continue;
      r.color!.value = hex(v.color);
      r.range.set(v.contrast, hex(v.color));
      r.val!.textContent = `${Math.round(v.contrast[0])}–${Math.round(v.contrast[1])}`;
    }
  };
  sync(store.getState().images);
  return { destroy: store.subscribe(s => s.images, sync) };
}
