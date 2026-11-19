// The images panel: per image, visibility, and for single-channel images
// colour and contrast (the pixel values drawn as black and as full colour, on
// one track with two thumbs). RGB images draw as they are. "add image" opens a
// choice of image type, then asks R to open a file dialog and add the chosen
// file as that type (LensViewer$add_image()).
import { state } from '../core/state.js';
import { store, actions, type ImageVis } from '../core/store.ts';
import { sendToR, onMessage, isConnected } from '../core/comms.js';
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

type ImageType = 'xenium' | 'if' | 'he';
const IMAGE_TYPES: { type: ImageType; title: string; text: string }[] = [
  { type: 'xenium', title: '10x Xenium image', text: "A morphology image from a Xenium output folder, read with Giotto's Xenium reader and placed in microns" },
  { type: 'if', title: 'IF', text: 'An immunofluorescence image, placed inside the data, to register by landmarks' },
  { type: 'he', title: 'H&E', text: 'An H&E image, placed inside the data, to register by landmarks' },
];

// The image type picker: one tile per type over the page. `onPick(type)`;
// Escape, a click outside or "cancel" closes it without a choice.
function pickImageType(onPick: (type: ImageType) => void): void {
  const overlay = Object.assign(document.createElement('div'), { className: 'lens-modal' });
  const box = Object.assign(document.createElement('div'), { className: 'lens-modal-box' });
  const head = Object.assign(document.createElement('div'), { className: 'lens-modal-title', textContent: 'add image' });
  const tiles = Object.assign(document.createElement('div'), { className: 'img-type-tiles' });
  const cancel = Object.assign(document.createElement('button'), { className: 'lens-modal-cancel', textContent: 'cancel' });
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
  for (const t of IMAGE_TYPES) {
    const tile = Object.assign(document.createElement('button'), { className: 'img-type-tile' });
    tile.dataset.type = t.type;
    tile.append(Object.assign(document.createElement('span'), { className: 'img-type-title', textContent: t.title }),
      Object.assign(document.createElement('span'), { className: 'img-type-text', textContent: t.text }));
    tile.addEventListener('click', () => { close(); onPick(t.type); });
    tiles.append(tile);
  }
  cancel.addEventListener('click', close);
  overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', onKey);
  box.append(head, tiles, cancel);
  overlay.append(box);
  document.body.append(overlay);
}

interface Row {
  item: HTMLElement; check: HTMLInputElement;
  color?: HTMLInputElement; range?: ReturnType<typeof dualRange>; val?: HTMLElement;
}

export function createImagesPanel(body: HTMLElement): PanelHandle {
  const list = Object.assign(document.createElement('div'), { className: 'ctl-body img-list' });
  body.append(list);
  const rows = new Map<string, Row>();

  const actionsRow = Object.assign(document.createElement('div'), { className: 'ctl-actions img-actions' });
  const add = Object.assign(document.createElement('button'), { className: 'img-add', textContent: 'add image',
    title: 'choose an image file (TIFF) in a dialog R opens; it can then be registered in the register panel' });
  const note = Object.assign(document.createElement('div'), { className: 'img-add-status' });
  actionsRow.append(add);
  list.append(actionsRow, note);
  if (!state.images?.size) note.textContent = 'no images';
  add.addEventListener('click', () => {
    if (!isConnected()) { note.textContent = 'R is not connected'; return; }
    pickImageType(type => {
      add.disabled = true;
      note.classList.remove('img-add-error');
      note.textContent = 'choose a file in the dialog R opened';
      sendToR('choose_image', { type });
    });
  });
  const offResult = onMessage('add_image_result', (r: { cancelled?: boolean; added?: string; error?: string }) => {
    add.disabled = false;
    note.textContent = r?.error ? r.error : r?.added ? `added ${r.added}` : state.images?.size ? '' : 'no images';
    note.classList.toggle('img-add-error', !!r?.error);
  });

  for (const [name, img] of state.images ?? []) {
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
  const offSync = store.subscribe(s => s.images, sync);
  return { destroy: () => { offSync(); offResult(); } };
}
