import { state } from './state.js';
import { PALETTE, MAX_LIST_ROWS } from './constants.js';
import { invalidateTx } from './data.js';

export function colorForGene(gi) {
  const [r, g, b] = PALETTE[gi % PALETTE.length];
  return `rgb(${r},${g},${b})`;
}

export function renderGeneList() {
  const genes   = state.manifest.layers.transcripts.genes;
  const term    = state.searchTerm.toLowerCase();
  const matches = term ? genes.filter(g => g.toLowerCase().includes(term)) : genes;
  const frag    = document.createDocumentFragment();

  for (const name of matches.slice(0, MAX_LIST_ROWS)) {
    const idx = state.geneIndex.get(name);
    const sel = state.selectedGenes.has(idx);
    const row = document.createElement('div');
    row.className = 'gene-row' + (sel ? ' selected' : '');
    const dot = document.createElement('span');
    dot.className = 'gene-dot';
    dot.style.background = sel ? colorForGene(idx) : 'transparent';
    const label = document.createElement('span');
    label.className = 'gene-name';
    label.textContent = name;
    row.appendChild(dot); row.appendChild(label);
    row.addEventListener('click', () => toggleGene(idx));
    frag.appendChild(row);
  }

  if (matches.length > MAX_LIST_ROWS) {
    const ov = document.createElement('div');
    ov.id = 'list-overflow';
    ov.textContent = `+${matches.length - MAX_LIST_ROWS} more — refine search`;
    frag.appendChild(ov);
  }

  document.getElementById('gene-list').replaceChildren(frag);
  const n = state.selectedGenes.size;
  document.getElementById('sel-count').textContent =
    n ? `${n} gene${n > 1 ? 's' : ''} selected` : '';
}

// onToggle callback injected by main.js to avoid circular import
let _onToggle = null;
export function setToggleCallback(fn) { _onToggle = fn; }

export function toggleGene(geneIdx) {
  if (state.selectedGenes.has(geneIdx)) state.selectedGenes.delete(geneIdx);
  else                                  state.selectedGenes.add(geneIdx);
  invalidateTx();
  renderGeneList();
  _onToggle?.();
}
