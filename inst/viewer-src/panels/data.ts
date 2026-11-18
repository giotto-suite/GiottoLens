// The Data panel: what the object shown holds that is not in the metadata
// yet (cell metadata columns, expression, spatial enrichments, dim
// reductions), from the catalog R lists at load (data/catalog.ts). Items are
// queued, each with how to treat it, and pulled together into the metadata:
// R makes one spatValues() call, as a job, and sends the metadata again with
// the pulled columns added. The ask is answered when the job ends; the job
// carries the panel's `ref`, by which the panel finds it to cancel it.
// viewer$catalog() and viewer$pull() are the same from R. A field that shows one item (color-by) takes it with the
// picker instead (panels/picker.ts), without adding a column.
import { state } from '../core/state.js';
import { store } from '../core/store.ts';
// @ts-ignore: plain JS module
import { askR, onConnect } from '../core/comms.js';
// @ts-ignore: plain JS module
import { MAX_LIST_ROWS } from '../core/constants.js';
import type { PanelHandle } from './dock.ts';
import { onJobs, runningJobs } from '../ui/jobs.ts';
import { loadCatalog, sourceLabel, columnFor, pullKeys, type CatalogSource, type ItemType, type Queued } from '../data/catalog.ts';

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);
const TYPES: ItemType[] = ['auto', 'categorical', 'continuous'];

export function createDataPanel(body: HTMLElement): PanelHandle {
  let sources: CatalogSource[] = [];
  let queue: Queued[] = [];
  let pulling: string | null = null;   // the running pull's ref
  const key = (q: { source: number; item: string }) => `${q.source}\u0000${q.item}`;

  const note   = el('div', { className: 'panel-note', textContent: 'waiting for R…' });
  const source = el('select', { className: 'ctl-select data-source' });
  const search = el('input', { className: 'ctl-input data-search', type: 'text',
    placeholder: 'search…', autocomplete: 'off', spellcheck: false });
  const srcRow = el('div', { className: 'alpha-row' });
  srcRow.append(el('label', { textContent: 'from' }), source);
  const pull  = el('button', { className: 'data-pull' });
  const clear = el('button', { className: 'data-clear', textContent: 'clear' });
  const actionsRow = el('div', { className: 'ctl-actions' });
  actionsRow.append(pull, clear);
  const status = el('div', { className: 'data-status' });
  // The pull button and its outcome stay in view however short the panel
  const head = el('div', { className: 'ctl-body gene-head' });
  head.append(srcRow, search, actionsRow, status);
  const list = el('div', { className: 'gene-list data-list' });
  const queued = el('div', { className: 'ctl-body data-queue' });
  const root = el('div', { className: 'data-panel' });
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
      const row = el('div', { className: 'gene-row data-item' + (on ? ' selected' : '') + (loaded ? ' loaded' : ''),
        title: loaded ? 'in the metadata; pulling again replaces it' : '' });
      row.dataset.item = item;
      row.append(el('span', { className: 'gene-name', textContent: item }),
        el('span', { className: 'data-mark', textContent: loaded ? '✓' : '' }));
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
      const row = el('div', { className: 'data-queued' });
      const type = el('select', { className: 'ctl-select data-type', title: 'how to treat it' });
      type.append(...TYPES.map(t => el('option', { value: t, textContent: t })));
      type.value = q.type;
      type.addEventListener('change', () => { q.type = type.value as ItemType; });
      const drop = el('button', { className: 'annot-row-btn data-drop', textContent: '×', title: 'remove' });
      drop.addEventListener('click', () => toggle(q.source, q.item));
      row.append(el('span', { className: 'data-queued-name', textContent: q.item,
        title: `${q.item} · ${sourceLabel(s, sources)}` }), type, drop);
      return row;
    }));
    pull.textContent = pulling ? 'pulling…' : queue.length ? `pull ${queue.length}` : 'pull';
    pull.disabled = !!pulling || !queue.length;
    clear.textContent = pulling ? 'cancel' : 'clear';
    clear.disabled = pulling ? pullJob() == null : !queue.length;
  }
  const pullJob = () => runningJobs().find(j => j.ref === pulling)?.id;

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
    const ref = pulling = `pull-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    status.textContent = '';
    status.classList.remove('error');
    renderQueue();
    try {
      const res = await askR('pull', { keys: pullKeys(queue), ref }) as { columns: string[] };
      queue = [];
      status.textContent = `pulled ${res.columns.length}: ${res.columns.join(', ')}`;
    } catch (e) {
      const cancelled = (e as { code?: string }).code === 'cancelled';
      status.textContent = cancelled ? 'cancelled' : String((e as Error).message ?? e);
      status.classList.toggle('error', !cancelled);
    } finally {
      pulling = null;
      renderQueue();
      renderList();
    }
  }

  let destroyed = false;
  async function load() {
    if (sources.length || destroyed) return;
    try {
      sources = await loadCatalog();
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
    if (!pulling) { queue = []; renderQueue(); renderList(); return; }
    const id = pullJob();
    if (id != null) void askR('cancel_job', { id }).catch(() => {});
  });
  // The cancel button needs the pull's job, which R reports as it starts
  const offJobs = onJobs(() => { if (pulling) renderQueue(); });
  renderQueue();
  void load();
  const offConnect = onConnect(() => void load());
  // Loaded marks follow the metadata
  const unsub = store.subscribe(s => s.metaVersion, renderList);

  return { destroy: () => { destroyed = true; unsub(); offJobs(); offConnect?.(); } };
}
