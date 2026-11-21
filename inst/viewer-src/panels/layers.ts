// The layers panel: how each layer is drawn, one collapsible section per
// layer (adr/0027). A section's header shows or hides the layer and sets its
// opacity (store `layers`, also set from R by set_layer()); its body holds
// the layer's own settings: the cells' colouring, legend and outlines
// (panels/cells.ts), the transcripts' genes and palette (transcripts.ts), the
// images' channels and contrast (images.ts), the annotations' names on the
// view and outlines. The annotations' list is the annotations panel's.
//
// A collapsed section keeps its body, so it is current when opened again.
// Which are open is config (`layerSections`, over each section's default).
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions, type LayerName, type LayerVis } from '../core/store.ts';
import type { PanelHandle } from './dock.ts';
import { createCellsPanel, createOutlineSection } from './cells.ts';
import { createTranscriptsPanel } from './transcripts.ts';
import { createImagesPanel } from './images.ts';

// `has`: whether this launch has the section; `drawn`: whether its layer has
// something to draw (the images' header waits for an image); `open`: open
// until the user says otherwise: the cells only, or the transcripts in a
// launch without cells
interface Section {
  id: string;
  layer: LayerName;
  has(): boolean;
  drawn?(): boolean;
  open(): boolean;
  create(body: HTMLElement): PanelHandle;
}
const SECTIONS: Section[] = [
  { id: 'cells', layer: 'poly', has: () => !!state.cells, open: () => true, create: createCellsPanel },
  // Open at first only without cells: with them, it waits for a click
  { id: 'transcripts', layer: 'tx', has: () => !!state.manifest?.layers?.transcripts,
    open: () => !state.cells, create: createTranscriptsPanel },
  { id: 'images', layer: 'img', has: () => true, drawn: () => !!state.images?.size, open: () => false,
    create: createImagesPanel },
  { id: 'annotations', layer: 'annotations', has: () => true, open: () => false, create: createAnnotationStyle },
];

// Names drawn on the view (store `annotNames`) and the outlines
function createAnnotationStyle(body: HTMLElement): PanelHandle {
  const names = el('input', { type: 'checkbox', className: 'annot-names' });
  const row = el('div', { className: 'alpha-row' });
  row.append(el('label', { textContent: 'names' }), names);
  const top = el('div', { className: 'ctl-body' });
  top.append(row);
  const outline = createOutlineSection('annotOutline');
  body.append(top, outline.el);
  names.addEventListener('change', () => actions.setAnnotNames(names.checked));
  const off = store.subscribe(s => s.annotNames, on => { names.checked = on; }, { fireImmediately: true });
  return { destroy() { off(); outline.destroy(); } };
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

const isOpen = (s: Section) => store.getState().layerSections[s.id] ?? s.open();

export function createLayersPanel(body: HTMLElement): PanelHandle {
  const root = el('div', { className: 'layer-sections' });
  body.append(root);
  const unsub: (() => void)[] = [];
  const handles: PanelHandle[] = [];

  const built = SECTIONS.filter(s => s.has()).map(s => {
    const check  = el('input', { type: 'checkbox', className: 'show', title: `show ${s.id}` });
    const slider = el('input', { type: 'range', className: 'alpha', min: '0', max: '100', title: 'opacity' });
    const value  = el('span', { className: 'alpha-val' });
    const toggle = el('button', { className: 'layer-toggle', title: `${s.id} settings` });
    toggle.append(el('i'), el('span', { className: 'layer-name', textContent: s.id }));
    (toggle.firstChild as HTMLElement).dataset.lucide = 'chevron-down';
    const head = el('div', { className: 'alpha-row layer-head' });
    head.dataset.layer = s.layer;
    head.append(toggle, check, slider, value);
    const section = el('section', { className: 'layer-section' });
    section.dataset.section = s.id;
    section.append(head);
    root.append(section);

    const content = el('div', { className: 'layer-body' });
    section.append(content);
    handles.push(s.create(content));
    toggle.addEventListener('click', () => actions.setLayerSection(s.id, !isOpen(s)));

    const sync = ({ show, alpha }: LayerVis) => {
      check.checked = show;
      slider.disabled = !show;
      slider.value = String(Math.round(alpha * 100));
      value.textContent = slider.value;
    };
    sync(store.getState().layers[s.layer]);
    unsub.push(store.subscribe(st => st.layers[s.layer], sync));
    check.addEventListener('change', () => actions.setLayer(s.layer, { show: check.checked }));
    slider.addEventListener('input', () => actions.setLayer(s.layer, { alpha: Number(slider.value) / 100 }));
    return { s, section, drawnEls: [check, slider, value] };
  });
  createIcons({ icons, root });

  const sync = () => {
    for (const { s, section, drawnEls } of built) {
      section.classList.toggle('collapsed', !isOpen(s));
      const drawn = s.drawn?.() ?? true;
      for (const e of drawnEls) e.style.visibility = drawn ? '' : 'hidden';
    }
  };
  sync();
  unsub.push(store.subscribe(st => st.layerSections, sync), store.subscribe(st => st.images, sync));

  return { destroy() { unsub.forEach(u => u()); handles.forEach(h => h.destroy()); } };
}
