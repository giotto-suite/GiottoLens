// Annotation list, name popup, and sync to R
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { sendToR } from '../core/comms.js';
import { fitZoom, escapeHtml } from './dom.js';
import { setViewState } from '../data/schedule.js';
import { createIcons, icons } from 'lucide';

export function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

function fitToAnnotation(annot) {
  const xs = annot.coords.map(p => p[0]);
  const ys = annot.coords.map(p => p[1]);
  const xmin = Math.min(...xs), xmax = Math.max(...xs);
  const ymin = Math.min(...ys), ymax = Math.max(...ys);
  const zoom = Math.min(fitZoom(Math.max(xmax - xmin, 1), Math.max(ymax - ymin, 1)) - 0.4,
                        state.currentViewState.maxZoom);
  setViewState({ ...state.currentViewState, target: [(xmin+xmax)/2, (ymin+ymax)/2, 0], zoom });
}

const TYPE_ABBR = { polygon: 'poly', rectangle: 'rect', freehand: 'free' };

function renderAnnotList() {
  const list  = document.getElementById('annot-list');
  const panel = document.getElementById('annot-panel');
  if (!list || !panel) return;
  const { annotations, selectedAnnotId } = store.getState();
  panel.style.display = annotations.length ? '' : 'none';
  list.replaceChildren();
  for (const a of annotations) {
    const row = document.createElement('div');
    row.className = 'annot-row' + (a.id === selectedAnnotId ? ' selected' : '');
    row.dataset.id = a.id;
    const tag  = escapeHtml(TYPE_ABBR[a.type] ?? a.type);
    const name = a.name ? escapeHtml(a.name) : '<span class="annot-unnamed">unnamed</span>';
    row.innerHTML =
      `<span class="annot-type-tag ${escapeHtml(a.type)}">${tag}</span>` +
      `<span class="annot-name-text">${name}</span>` +
      `<button class="annot-row-btn annot-row-nav" title="zoom to"><i data-lucide="locate"></i></button>` +
      `<button class="annot-row-btn annot-row-del" title="delete"><i data-lucide="x"></i></button>`;
    row.querySelector('.annot-row-nav').addEventListener('click', e => {
      e.stopPropagation();
      fitToAnnotation(a);
    });
    row.querySelector('.annot-row-del').addEventListener('click', e => {
      e.stopPropagation();
      actions.removeAnnotation(a.id);
    });
    row.addEventListener('click', () =>
      actions.selectAnnotation(a.id === store.getState().selectedAnnotId ? null : a.id));
    list.appendChild(row);
  }
  createIcons({ icons, nodes: list.querySelectorAll('[data-lucide]') });
}

export function initAnnotations() {
  const $popup = document.getElementById('annot-popup');
  const $name  = document.getElementById('annot-name');
  const $type  = document.getElementById('annot-type');

  store.subscribe(s => s.selectedAnnotId, id => {
    renderAnnotList();
    const annot = id && store.getState().annotations.find(a => a.id === id);
    if (annot) {
      if ($name) $name.value = annot.name ?? '';
      if ($type) $type.textContent = annot.type ?? '';
      $popup?.classList.add('visible');
    } else {
      $popup?.classList.remove('visible');
    }
  });

  $name?.addEventListener('input', () => {
    const id = store.getState().selectedAnnotId;
    if (id) actions.renameAnnotation(id, $name.value);
  });

  store.subscribe(s => s.annotations, annotations => {
    sendToR('annotations_update', {
      annotations: annotations.map(a => ({
        id: a.id, type: a.type, name: a.name ?? '',
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } }),
      })),
    });
    renderAnnotList();
  });
}
