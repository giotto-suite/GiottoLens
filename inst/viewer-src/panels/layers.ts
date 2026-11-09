// The layers panel: each layer shown or hidden, and its opacity (store
// `layers`, also set from R by set_layer()). A layer this launch does not have
// gets no row; the images row appears once an image has opened.
import { state } from '../core/state.js';
import { store, actions, type LayerName, type LayerVis } from '../core/store.ts';
import type { PanelHandle } from './dock.ts';

const ROWS: { layer: LayerName; label: string; has(): boolean }[] = [
  { layer: 'poly',        label: 'cells',       has: () => true },
  { layer: 'tx',          label: 'transcripts', has: () => !!state.manifest?.layers?.transcripts },
  { layer: 'img',         label: 'images',      has: () => !!state.images?.size },
  { layer: 'annotations', label: 'annotations', has: () => true },
];

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

export function createLayersPanel(body: HTMLElement): PanelHandle {
  const root = el('div', { className: 'ctl-body' });
  body.append(root);
  const unsub: (() => void)[] = [];

  const rows = ROWS.map(({ layer, label, has }) => {
    const check  = el('input', { type: 'checkbox', className: 'show' });
    const slider = el('input', { type: 'range', className: 'alpha', min: '0', max: '100' });
    const value  = el('span', { className: 'alpha-val' });
    const row = el('div', { className: 'alpha-row' });
    row.dataset.layer = layer;
    row.append(check, el('label', { textContent: label }), slider, value);
    root.append(row);

    const sync = ({ show, alpha }: LayerVis) => {
      check.checked = show;
      slider.disabled = !show;
      slider.value = String(Math.round(alpha * 100));
      value.textContent = slider.value;
    };
    sync(store.getState().layers[layer]);
    unsub.push(store.subscribe(s => s.layers[layer], sync));
    check.addEventListener('change', () => actions.setLayer(layer, { show: check.checked }));
    slider.addEventListener('input', () => actions.setLayer(layer, { alpha: Number(slider.value) / 100 }));
    return { row, has };
  });

  const showRows = () => { for (const { row, has } of rows) row.style.display = has() ? '' : 'none'; };
  showRows();
  unsub.push(store.subscribe(s => s.images, showRows));

  return { destroy() { unsub.forEach(u => u()); } };
}
