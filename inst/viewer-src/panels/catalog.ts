// The catalog panel: what the object shown holds that is not in the
// metadata yet (cell metadata columns, expression, spatial enrichments, dim
// reductions), listed by R from the object at load (R/catalog.R). Items are
// queued, each with how to treat it, and pulled together: R runs one
// spatValues() call over the snapshot as a job in its worker and sends the
// metadata again with the pulled columns added. The ask is answered when the
// job ends; its `job` messages carry the panel's `ref` and the id to cancel
// it with. viewer$catalog() and viewer$pull() are the same from R.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
// @ts-ignore: plain JS module
import { askR, onConnect, onMessage } from '../core/comms.js';
// @ts-ignore: plain JS module
import { MAX_LIST_ROWS } from '../core/constants.js';
import type { PanelHandle } from './dock.ts';

export interface CatalogSource {
  id: number;
  slot: 'cell_metadata' | 'expression' | 'spatial_enrichment' | 'dimension_reduction';
  feat_type: string;
  name?: string;
  method?: string;
  items: string[];
}
interface Payload {
  spat_unit: string;
  sources: (Omit<CatalogSource, 'items'> & { items?: string[]; same_as?: number })[];
}
export type ItemType = 'auto' | 'categorical' | 'continuous';
export interface Queued { source: number; item: string; type: ItemType }

// R sends a list of names once when sources share it (`same_as`)
export function expandCatalog(p: Payload): CatalogSource[] {
  const byId = new Map<number, string[]>();
  return p.sources.map(s => {
    const items = s.items ?? byId.get(s.same_as!) ?? [];
    byId.set(s.id, items);
    const { same_as: _, ...rest } = s;
    return { ...rest, items };
  });
}

const SLOT_LABELS: Record<CatalogSource['slot'], string> = {
  cell_metadata: 'cell metadata', expression: 'expression',
  spatial_enrichment: 'enrichment', dimension_reduction: 'dim reduction',
};
// The feature type only when there is more than one
export function sourceLabel(s: CatalogSource, all: CatalogSource[]): string {
  const ft = new Set(all.map(o => o.feat_type)).size > 1 ? ` (${s.feat_type})` : '';
  return SLOT_LABELS[s.slot] + (s.name ? ` · ${s.name}` : '') + ft;
}

// The column an item becomes when pulled on its own, as R names it: dim
// reduction axes <reduction>_<axis>, other names with characters other than
// letters, digits and _ replaced
export function columnFor(s: CatalogSource, item: string): string {
  const name = s.slot === 'dimension_reduction' ? `${s.name}_${s.items.indexOf(item) + 1}` : item;
  return name.replace(/[^A-Za-z0-9_]/g, '_');
}

// The `pull` ask's keys: one per source, a type per item
export function pullKeys(queue: Queued[]): { source: number; items: string[]; types: ItemType[] }[] {
  const keys = new Map<number, { source: number; items: string[]; types: ItemType[] }>();
  for (const q of queue) {
    const k = keys.get(q.source) ?? { source: q.source, items: [], types: [] };
    k.items.push(q.item);
    k.types.push(q.type);
    keys.set(q.source, k);
  }
  return [...keys.values()];
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);
const TYPES: ItemType[] = ['auto', 'categorical', 'continuous'];

export function createCatalogPanel(body: HTMLElement): PanelHandle {
  let sources: CatalogSource[] = [];
  let queue: Queued[] = [];
  let pulling = false;
  let jobId: number | null = null;   // the running pull's, from its `job` message
  const key = (q: { source: number; item: string }) => `${q.source}\u0000${q.item}`;

  const note   = el('div', { className: 'panel-note', textContent: 'waiting for R…' });
  const source = el('select', { className: 'ctl-select catalog-source' });
  const search = el('input', { className: 'ctl-input catalog-search', type: 'text',
    placeholder: 'search…', autocomplete: 'off', spellcheck: false });
  const srcRow = el('div', { className: 'alpha-row' });
  srcRow.append(el('label', { textContent: 'from' }), source);
  const pull  = el('button', { className: 'catalog-pull' });
  const clear = el('button', { className: 'catalog-clear', textContent: 'clear' });
  const actionsRow = el('div', { className: 'ctl-actions' });
  actionsRow.append(pull, clear);
  const status = el('div', { className: 'catalog-status' });
  // The pull button and its outcome stay in view however short the panel
  const head = el('div', { className: 'ctl-body gene-head' });
  head.append(srcRow, search, actionsRow, status);
  const list = el('div', { className: 'gene-list catalog-list' });
  const queued = el('div', { className: 'ctl-body catalog-queue' });
  const root = el('div', { className: 'catalog' });
  root.append(head, list, queued);
  root.style.display = 'none';
  body.append(note, root);

  const current = () => sources.find(s => String(s.id) === source.value);

  function renderList() {
    const s = current();
    if (!s) { list.replaceChildren(); return; }
    const inQueue = new Set(queue.map(key));
    const term = search.value.toLowerCase();
    const matches = term ? s.items.filter(i => i.toLowerCase().includes(term)) : s.items;
    const rows = matches.slice(0, MAX_LIST_ROWS).map(item => {
      const on = inQueue.has(key({ source: s.id, item }));
      const loaded = !!state.metaInfo?.has(columnFor(s, item));
      const row = el('div', { className: 'gene-row catalog-item' + (on ? ' selected' : '') + (loaded ? ' loaded' : ''),
        title: loaded ? 'in the metadata; pulling again replaces it' : '' });
      row.dataset.item = item;
      row.append(el('span', { className: 'gene-name', textContent: item }),
        el('span', { className: 'catalog-mark', textContent: loaded ? '✓' : '' }));
      row.addEventListener('click', () => toggle(s.id, item));
      return row;
    });
    if (matches.length > MAX_LIST_ROWS)
      rows.push(el('div', { className: 'list-overflow', textContent: `+${matches.length - MAX_LIST_ROWS} more — refine search` }));
    list.replaceChildren(...rows);
  }

  function renderQueue() {
    queued.style.display = queue.length ? '' : 'none';
    queued.replaceChildren(...queue.map(q => {
      const s = sources.find(o => o.id === q.source)!;
      const row = el('div', { className: 'catalog-queued' });
      const type = el('select', { className: 'ctl-select catalog-type', title: 'how to treat it' });
      type.append(...TYPES.map(t => el('option', { value: t, textContent: t })));
      type.value = q.type;
      type.addEventListener('change', () => { q.type = type.value as ItemType; });
      const drop = el('button', { className: 'annot-row-btn catalog-drop', textContent: '×', title: 'remove' });
      drop.addEventListener('click', () => toggle(q.source, q.item));
      row.append(el('span', { className: 'catalog-queued-name', textContent: q.item,
        title: `${q.item} · ${sourceLabel(s, sources)}` }), type, drop);
      return row;
    }));
    pull.textContent = pulling ? 'pulling…' : queue.length ? `pull ${queue.length}` : 'pull';
    pull.disabled = pulling || !queue.length;
    clear.textContent = pulling ? 'cancel' : 'clear';
    clear.disabled = pulling ? jobId == null : !queue.length;
  }

  function toggle(src: number, item: string) {
    if (pulling) return;
    const k = key({ source: src, item });
    const i = queue.findIndex(q => key(q) === k);
    if (i >= 0) queue.splice(i, 1);
    else queue.push({ source: src, item, type: 'auto' });
    renderQueue();
    renderList();
  }

  async function doPull() {
    if (!queue.length || pulling) return;
    pulling = true;
    status.textContent = '';
    status.classList.remove('error');
    renderQueue();
    const ref = `pull-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const offJob = onMessage('job', (j: { id: number; ref?: string }) => {
      if (j.ref === ref && jobId == null) { jobId = j.id; renderQueue(); }
    });
    try {
      const res = await askR('pull', { keys: pullKeys(queue), ref }) as { columns: string[] };
      queue = [];
      status.textContent = `pulled ${res.columns.length}: ${res.columns.join(', ')}`;
    } catch (e) {
      const cancelled = (e as { code?: string }).code === 'cancelled';
      status.textContent = cancelled ? 'cancelled' : String((e as Error).message ?? e);
      status.classList.toggle('error', !cancelled);
    } finally {
      offJob();
      jobId = null;
      pulling = false;
      renderQueue();
      renderList();
    }
  }

  let destroyed = false;
  async function load() {
    if (sources.length || destroyed) return;
    try {
      sources = expandCatalog(await askR('catalog') as Payload);
    } catch (e) {
      note.textContent = String((e as Error).message ?? e);
      return;
    }
    if (destroyed) return;
    source.replaceChildren(...sources.map(s => el('option', { value: String(s.id),
      textContent: `${sourceLabel(s, sources)} (${s.items.length})` })));
    note.style.display = sources.length ? 'none' : '';
    note.textContent = 'nothing to pull';
    root.style.display = sources.length ? '' : 'none';
    renderList();
    renderQueue();
  }

  source.addEventListener('change', () => { search.value = ''; renderList(); });
  search.addEventListener('input', renderList);
  pull.addEventListener('click', doPull);
  clear.addEventListener('click', () => {
    if (pulling) { if (jobId != null) void askR('cancel_job', { id: jobId }).catch(() => {}); return; }
    queue = []; renderQueue(); renderList();
  });
  renderQueue();
  void load();
  const offConnect = onConnect(() => void load());
  // Loaded marks follow the metadata
  const unsub = store.subscribe(s => s.metaVersion, renderList);

  return { destroy: () => { destroyed = true; unsub(); offConnect?.(); } };
}
