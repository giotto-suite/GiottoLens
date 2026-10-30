// Gene list in the side panel
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { PALETTES, MAX_LIST_ROWS } from '../core/constants.js';

let _search = '';
export function setGeneSearch(term) { _search = term; renderGeneList(); }

export function colorForGene(gi) {
  const pal = PALETTES[store.getState().txPalette] ?? PALETTES[0];
  const [r, g, b] = pal[gi % pal.length];
  return `rgb(${r},${g},${b})`;
}

export function renderGeneList() {
  const genes = state.manifest?.layers.transcripts?.genes;
  if (!genes) return;
  const selected = new Set(store.getState().genes);
  const term     = _search.toLowerCase();
  const matches  = term ? genes.filter(g => g.toLowerCase().includes(term)) : genes;
  const frag     = document.createDocumentFragment();

  for (const name of matches.slice(0, MAX_LIST_ROWS)) {
    const idx = state.geneIndex.get(name);
    const sel = selected.has(idx);
    const row = document.createElement('div');
    row.className = 'gene-row' + (sel ? ' selected' : '');
    const dot = document.createElement('span');
    dot.className = 'gene-dot';
    dot.style.background = sel ? colorForGene(idx) : 'transparent';
    const label = document.createElement('span');
    label.className = 'gene-name';
    label.textContent = name;
    row.appendChild(dot); row.appendChild(label);
    row.addEventListener('click', () => actions.toggleGene(idx));
    frag.appendChild(row);
  }

  if (matches.length > MAX_LIST_ROWS) {
    const ov = document.createElement('div');
    ov.id = 'list-overflow';
    ov.textContent = `+${matches.length - MAX_LIST_ROWS} more — refine search`;
    frag.appendChild(ov);
  }

  document.getElementById('gene-list').replaceChildren(frag);
  const n = selected.size;
  document.getElementById('gene-count').textContent =
    n ? `${n} gene${n > 1 ? 's' : ''} selected` : '';
}
