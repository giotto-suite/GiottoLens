// The cell table: one row per cell in the selection of every other source
// (all cells when there is none), one column per metadata column. Rows are
// drawn from the typed arrays the page holds, only those in view, so a
// million rows scroll without paging from R. Cell IDs are asked of R for the
// rows in view only: the page keys nothing by ID (adr/0002).
//
// Picked rows are this panel's rule (source `table`, an `ids` rule), combined
// with the other sources like any rule: they add to the selection, or in
// cross-filter mode narrow it. The rows never include the table's own rule,
// as the histogram leaves out its own, so picking rows does not shrink them.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
// @ts-ignore: plain JS module
import { askR } from '../core/comms.js';
import { maskExcept, ctx as selCtx } from '../selection/selection.ts';
import { evaluate, encodeMask, primeMask, countMask, type Rule } from '../selection/rules.ts';
import { metaColumn, metaValue, needColumns, onColumnsLoaded } from '../data/meta.ts';
import type { PanelCtx, PanelHandle } from './dock.ts';

export const ROW_H = 20;            // px
const MAX_H = 8_000_000;            // px: browsers cap an element's height near 2^25
const OVERSCAN = 4;
const COL_W = 110, ID_W = 150;      // px
const ID_CACHE = 20_000;            // cell IDs kept from R
const ID_DELAY_MS = 60;             // a scroll settles before IDs are asked for

// Cell indices of the rows: the cells `mask` holds, or all `n`
export function tableRows(mask: Uint8Array | null, n: number): Int32Array {
  if (!mask) return Int32Array.from({ length: n }, (_, i) => i);
  let k = 0;
  for (let i = 0; i < n; i++) k += mask[i];
  const out = new Int32Array(k);
  for (let i = 0, j = 0; i < n; i++) if (mask[i]) out[j++] = i;
  return out;
}

// The rows in view at `scrollTop`, and where to draw them. Past `maxH` the
// scroll range is scaled to the rows, and the rows drawn at the top of the
// view, so any number of rows scrolls end to end.
export function windowFor(scrollTop: number, viewH: number, nRows: number, rowH = ROW_H, maxH = MAX_H) {
  const full = nRows * rowH;
  const height = Math.min(full, maxH);
  const shown = Math.ceil(viewH / rowH) + 1;
  let first: number, top: number;
  if (full <= maxH) {
    first = Math.floor(scrollTop / rowH);
    top = first * rowH;
  } else {
    const range = Math.max(1, height - viewH);
    first = Math.round(Math.min(1, scrollTop / range) * Math.max(0, nRows - shown + 1));
    top = scrollTop;
  }
  first = Math.max(0, Math.min(first, Math.max(0, nRows - 1)));
  // Scaled, the rows are drawn at the view's top: more would grow the scroll range
  const extra = full <= maxH ? OVERSCAN : 0;
  return { first, count: Math.max(0, Math.min(shown + extra, nRows - first)), top, height };
}

export type PickMode = 'replace' | 'toggle' | 'range';
// Picks after a click on row `at` (a position in `rows`): replace them with
// that cell (or none, when it was the only one), toggle it, or add the rows
// from `anchor` to it
export function applyPick(picks: Uint8Array | null, n: number, rows: Int32Array, at: number,
  mode: PickMode, anchor: number | null): Uint8Array {
  const cell = rows[at];
  if (mode === 'replace') {
    const only = !!picks && picks[cell] === 1 && countMask(picks) === 1;
    const m = new Uint8Array(n);
    if (!only) m[cell] = 1;
    return m;
  }
  const m = picks ? new Uint8Array(picks) : new Uint8Array(n);
  if (mode === 'toggle' || anchor == null) { m[cell] ^= 1; return m; }
  const [a, b] = anchor < at ? [anchor, at] : [at, anchor];
  for (let k = Math.max(0, a); k <= Math.min(b, rows.length - 1); k++) m[rows[k]] = 1;
  return m;
}

const fmt = (v: string | number | null): string => {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  return Number.isInteger(v) ? String(v) : String(+v.toPrecision(5));
};

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

export function createTablePanel(body: HTMLElement, ctx: PanelCtx): PanelHandle {
  const source = ctx.id === 'table' ? 'table' : `table:${ctx.id}`;
  const n = state.cells?.n ?? 0;

  const count = el('span', { className: 'table-count' });
  const clear = el('button', { className: 'table-clear', textContent: 'clear picks' });
  const hint  = el('span', { className: 'table-hint', textContent: 'click a row; ⌘/ctrl toggles, shift adds a range' });
  const bar = el('div', { className: 'table-bar' });
  bar.append(count, clear, hint);
  const scroll = el('div', { className: 'table-scroll' });
  const inner  = el('div', { className: 'table-inner' });
  const head   = el('div', { className: 'table-row table-header' });
  const rowsEl = el('div', { className: 'table-rows' });
  inner.append(head, rowsEl);
  scroll.append(inner);
  body.append(bar, scroll);

  let columns: string[] = [];
  let rows: Int32Array = new Int32Array(0);
  let rowsFor: unknown[] | null = null;   // the rules and mode the rows were made from
  let anchor: number | null = null;       // the last row clicked, for shift
  const ids = new Map<number, string>();
  let idTimer: ReturnType<typeof setTimeout> | undefined;

  const ownRule = () => store.getState().rules[source] ?? null;
  const picks = (): Uint8Array | null => {
    const r = ownRule(), c = selCtx();
    return r && c ? evaluate(r, c) : null;
  };

  // The rows follow every source but this one
  function updateRows(): boolean {
    const s = store.getState();
    const key = [s.combine, ...Object.entries(s.rules).filter(([k]) => k !== source).flat()];
    if (rowsFor && key.length === rowsFor.length && key.every((v, i) => v === rowsFor![i])) return false;
    const others = key.length > 1;
    const mask = maskExcept(source);
    // No mask with other rules: their columns are loading, so try again on
    // the next selection
    rowsFor = others && !mask ? null : key;
    rows = tableRows(mask, n);
    anchor = null;
    return true;
  }

  function buildHeader() {
    columns = [...(state.metaInfo?.keys() ?? [])] as string[];
    const cells = [el('div', { className: 'table-cell table-id', textContent: 'cell_ID' }),
      ...columns.map(c => el('div', { className: 'table-cell', textContent: c, title: c }))];
    head.replaceChildren(...cells);
    inner.style.width = `${ID_W + columns.length * COL_W}px`;
    void needColumns(columns);
  }

  function render() {
    if (!ctx.visible()) return;
    const viewH = scroll.clientHeight - ROW_H;   // under the header
    const w = windowFor(scroll.scrollTop, Math.max(viewH, ROW_H), rows.length);
    inner.style.height = `${w.height + ROW_H}px`;
    rowsEl.style.top = `${w.top + ROW_H}px`;
    const p = picks();
    const cols = columns.map(c => metaColumn(c));
    const out: HTMLElement[] = [];
    const missing: number[] = [];
    for (let k = w.first; k < w.first + w.count; k++) {
      const cell = rows[k];
      const row = el('div', { className: 'table-row' + (p?.[cell] ? ' picked' : '') });
      row.dataset.row = String(k);
      const id = ids.get(cell);
      if (id == null) missing.push(cell);
      row.append(el('div', { className: 'table-cell table-id', textContent: id ?? '…' }),
        ...cols.map(c => el('div', { className: 'table-cell', textContent: c ? fmt(metaValue(c, cell)) : '…' })));
      out.push(row);
    }
    rowsEl.replaceChildren(...out);
    const picked = p ? countMask(p) : 0;
    count.textContent = `${rows.length.toLocaleString()} cells` + (picked ? ` · ${picked.toLocaleString()} picked` : '');
    clear.disabled = !ownRule();
    if (missing.length) askIds(missing);
  }

  function askIds(cells: number[]) {
    clearTimeout(idTimer);
    idTimer = setTimeout(async () => {
      try {
        const res = await askR('cell_ids', { cells }) as { ids: string[] };
        if (ids.size + cells.length > ID_CACHE) ids.clear();
        cells.forEach((c, i) => ids.set(c, res.ids[i]));
        render();
      } catch { /* disconnected or a reload: the rows ask again */ }
    }, ID_DELAY_MS);
  }

  rowsEl.addEventListener('click', e => {
    const row = (e.target as HTMLElement).closest('.table-row') as HTMLElement | null;
    if (!row?.dataset.row) return;
    const at = Number(row.dataset.row);
    const mode: PickMode = e.shiftKey ? 'range' : (e.metaKey || e.ctrlKey) ? 'toggle' : 'replace';
    const m = applyPick(picks(), n, rows, at, mode, anchor);
    anchor = at;
    if (!countMask(m)) { actions.setRule(source, null); return; }
    const rule: Rule = { source, kind: 'ids', params: { mask: encodeMask(m, n) } };
    primeMask(rule, m);
    actions.setRule(source, rule);
  });
  clear.addEventListener('click', () => actions.setRule(source, null));
  scroll.addEventListener('scroll', render, { passive: true });
  const resize = new ResizeObserver(() => render());
  resize.observe(scroll);

  const refresh = () => { updateRows(); render(); };
  const unsub = [
    store.subscribe(s => s.rules, refresh),
    store.subscribe(s => s.combine, refresh),
    store.subscribe(s => s.selection.version, refresh),
    onColumnsLoaded(render),
  ];
  buildHeader();
  updateRows();
  render();

  return {
    destroy: () => { unsub.forEach(f => f()); resize.disconnect(); clearTimeout(idTimer); },
    show: refresh,
  };
}
