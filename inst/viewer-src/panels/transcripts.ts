// The transcripts panel: genes to highlight in the transcript layer (store
// `genes`, also set from R by show_genes()), found by search; colour all
// genes, the palette, and clearing them.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { PALETTES, MAX_LIST_ROWS } from '../core/constants.js';
import type { PanelHandle } from './dock.ts';

const PALETTE_LABELS = ['muted', 'vivid'];

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

function colorForGene(gi: number): string {
  const pal = PALETTES[store.getState().txPalette] ?? PALETTES[0];
  const [r, g, b] = pal[gi % pal.length];
  return `rgb(${r},${g},${b})`;
}

export function createTranscriptsPanel(body: HTMLElement): PanelHandle {
  const genes: string[] = state.manifest.layers.transcripts.genes;
  const search   = el('input', { className: 'ctl-input gene-search', type: 'text', placeholder: 'search genes…',
    autocomplete: 'off', spellcheck: false });
  const colorAll = el('button', { className: 'color-all', textContent: 'color all' });
  const palette  = el('button', { className: 'palette' });
  const clear    = el('button', { className: 'clear', textContent: 'clear' });
  const count    = el('span', { className: 'gene-count' });
  const actionsRow = el('div', { className: 'ctl-actions' });
  actionsRow.append(colorAll, palette, clear, count);
  const head = el('div', { className: 'ctl-body gene-head' });
  head.append(search, actionsRow);
  const list = el('div', { className: 'gene-list' });
  body.append(head, list);

  search.addEventListener('input', render);
  colorAll.addEventListener('click', () => actions.setColorAll(!store.getState().colorAll));
  palette.addEventListener('click', () =>
    actions.setTxPalette((store.getState().txPalette + 1) % PALETTE_LABELS.length));
  clear.addEventListener('click', () => actions.clearGenes());

  function render() {
    const s = store.getState();
    colorAll.classList.toggle('active', s.colorAll);
    palette.textContent = PALETTE_LABELS[s.txPalette];
    const selected = new Set(s.genes);
    const term = search.value.toLowerCase();
    const matches = term ? genes.filter(g => g.toLowerCase().includes(term)) : genes;
    const rows = matches.slice(0, MAX_LIST_ROWS).map(name => {
      const idx = state.geneIndex.get(name);
      const sel = selected.has(name);
      const row = el('div', { className: 'gene-row' + (sel ? ' selected' : '') });
      const dot = el('span', { className: 'gene-dot' });
      dot.style.background = sel ? colorForGene(idx) : 'transparent';
      row.append(dot, el('span', { className: 'gene-name', textContent: name }));
      row.addEventListener('click', () => actions.toggleGene(name));
      return row;
    });
    if (matches.length > MAX_LIST_ROWS)
      rows.push(el('div', { className: 'list-overflow', textContent: `+${matches.length - MAX_LIST_ROWS} more — refine search` }));
    list.replaceChildren(...rows);
    const n = selected.size;
    count.textContent = n ? `${n} gene${n > 1 ? 's' : ''} selected` : '';
  }
  render();
  const unsub = store.subscribe(s => [s.genes, s.txPalette, s.colorAll], render,
    { equalityFn: (a, b) => a.every((v, i) => v === b[i]) });

  return { destroy: unsub };
}
