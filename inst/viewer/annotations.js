import { state }          from './state.js';
import { renderLayers }   from './render.js';
import { notify, onCoord } from './coordination.js';
import { sendToR }        from './comms.js';
import { updateScalebar } from './ui.js';

export function generateAnnotId() {
  return `ann_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

export function syncAnnotationsToR() { notify('annotations'); }

function fitToAnnotation(annot) {
  const xs = annot.coords.map(p => p[0]);
  const ys = annot.coords.map(p => p[1]);
  const xmin = Math.min(...xs), xmax = Math.max(...xs);
  const ymin = Math.min(...ys), ymax = Math.max(...ys);
  const w = Math.max(xmax - xmin, 1), h = Math.max(ymax - ymin, 1);
  const zoom = Math.min(
    Math.log2(Math.min((window.innerWidth - 260) / w, window.innerHeight / h)) - 0.4,
    state.currentViewState.maxZoom
  );
  const newVS = { ...state.currentViewState, target: [(xmin+xmax)/2, (ymin+ymax)/2, 0], zoom };
  state.deckgl.setProps({ viewState: newVS });
  state.currentViewState = newVS;
  updateScalebar(newVS);
  renderLayers(newVS);
}

const TYPE_ABBR = { polygon: 'poly', rectangle: 'rect', freehand: 'free' };

function renderAnnotList() {
  const list  = document.getElementById('annot-list');
  const panel = document.getElementById('annot-panel');
  if (!list || !panel) return;
  panel.style.display = state.annotations.length ? '' : 'none';
  list.innerHTML = '';
  state.annotations.forEach(a => {
    const row = document.createElement('div');
    row.className = 'annot-row' + (a.id === state.selectedAnnotId ? ' selected' : '');
    row.dataset.id = a.id;
    const tag  = TYPE_ABBR[a.type] ?? a.type;
    const name = a.name ? a.name : '<span class="annot-unnamed">unnamed</span>';
    row.innerHTML =
      `<span class="annot-type-tag ${a.type}">${tag}</span>` +
      `<span class="annot-name-text">${name}</span>` +
      `<button class="annot-row-btn annot-row-nav" title="zoom to"><i data-lucide="locate"></i></button>` +
      `<button class="annot-row-btn annot-row-del" title="delete"><i data-lucide="x"></i></button>`;
    row.querySelector('.annot-row-nav').addEventListener('click', e => {
      e.stopPropagation();
      fitToAnnotation(a);
    });
    row.querySelector('.annot-row-del').addEventListener('click', e => {
      e.stopPropagation();
      state.annotations = state.annotations.filter(x => x.id !== a.id);
      if (state.selectedAnnotId === a.id) { state.selectedAnnotId = null; notify('annotSelect'); }
      syncAnnotationsToR();
      renderLayers(state.currentViewState);
    });
    row.addEventListener('click', () => {
      const newId = a.id === state.selectedAnnotId ? null : a.id;
      state.selectedAnnotId = newId;
      notify('annotSelect');
      renderLayers(state.currentViewState);
    });
    list.appendChild(row);
  });
  lucide.createIcons({ nodes: list.querySelectorAll('[data-lucide]') });
}

export function initAnnotations() {
  const $annotPopup = document.getElementById('annot-popup');
  const $annotName  = document.getElementById('annot-name');
  const $annotType  = document.getElementById('annot-type');

  onCoord('annotSelect', () => {
    const id = state.selectedAnnotId;
    if (id) {
      const annot = state.annotations.find(a => a.id === id);
      if ($annotName) $annotName.value      = annot?.name ?? '';
      if ($annotType) $annotType.textContent = annot?.type ?? '';
      $annotPopup?.classList.add('visible');
    } else {
      $annotPopup?.classList.remove('visible');
    }
  });

  $annotName?.addEventListener('input', () => {
    if (!state.selectedAnnotId) return;
    state.annotations = state.annotations.map(a =>
      a.id === state.selectedAnnotId ? { ...a, name: $annotName.value } : a
    );
    syncAnnotationsToR();
  });

  onCoord('annotations', () => {
    sendToR('annotations_update', {
      annotations: state.annotations.map(a => ({
        id: a.id, type: a.type, name: a.name ?? '',
        geojson: JSON.stringify({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [a.coords] } })
      }))
    });
    renderAnnotList();
  });
}
