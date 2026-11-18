// The picker: a popover from a field's button for choosing what the field
// shows, a metadata column or one item of the object shown (data/items.ts),
// by source (the metadata, then each catalog source) and by search within
// it. Picking an item reads it first (R's `item` ask), so the field never
// holds one that cannot be read and an error shows here. One picker is open
// at a time; it closes on a pick, Escape, or a click outside. The Data panel
// (panels/data.ts) is where items are pulled into the metadata instead.
import { state } from '../core/state.js';
// @ts-ignore: plain JS module
import { MAX_LIST_ROWS } from '../core/constants.js';
import { loadCatalog, sourceLabel, type CatalogSource } from '../data/catalog.ts';
import { itemKey, refOf, parseItemKey, needItems } from '../data/items.ts';

export interface PickerOptions {
  anchor: HTMLElement;
  current?: string | null;           // the field's value: opens at its source
  onPick: (field: string) => void;   // a column name or an item key, once readable
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

const META = 'meta';
let close: (() => void) | null = null;

export const closePicker = () => close?.();

export function openPicker(opts: PickerOptions): void {
  closePicker();
  let sources: CatalogSource[] = [];
  let busy = false;

  const section = el('select', { className: 'ctl-select picker-source', title: 'where to pick from' });
  const search = el('input', { className: 'ctl-input picker-search', type: 'text',
    placeholder: 'search…', autocomplete: 'off', spellcheck: false });
  const list = el('div', { className: 'gene-list picker-list' });
  const status = el('div', { className: 'picker-status' });
  const root = el('div', { className: 'picker' });
  root.append(section, search, list, status);
  document.body.append(root);

  const metaNames = () => [...(state.metaInfo?.keys() ?? [])] as string[];
  const current = () => sources.find(s => String(s.id) === section.value);

  function options() {
    const keep = section.value;
    const opt = (value: string, text: string) => el('option', { value, textContent: text });
    section.replaceChildren(
      ...(metaNames().length ? [opt(META, `metadata (${metaNames().length})`)] : []),
      ...sources.map(s => opt(String(s.id), `${sourceLabel(s, sources)} (${s.items.length})`)));
    if ([...section.options].some(o => o.value === keep)) section.value = keep;
  }

  // The source the field's value is from
  function startAt(field: string | null | undefined) {
    const r = field ? parseItemKey(field) : null;
    const s = r && sources.find(o => o.slot === r.slot && o.feat_type === r.feat_type &&
      (o.name ?? '') === (r.name ?? '') && (o.method ?? '') === (r.method ?? ''));
    if (s) section.value = String(s.id);
  }

  function render() {
    const s = current();
    const names = s ? s.items : section.value === META ? metaNames() : [];
    const term = search.value.toLowerCase();
    const matches = term ? names.filter(n => n.toLowerCase().includes(term)) : names;
    const rows = matches.slice(0, MAX_LIST_ROWS).map(name => {
      const field = s ? itemKey(refOf(s, name)) : name;
      const row = el('div', { className: 'gene-row picker-item' + (field === opts.current ? ' selected' : '') });
      row.dataset.item = name;
      row.dataset.field = field;
      row.append(el('span', { className: 'gene-name', textContent: name }));
      row.addEventListener('click', () => void pick(field));
      return row;
    });
    if (matches.length > MAX_LIST_ROWS)
      rows.push(el('div', { className: 'list-overflow', textContent: `+${matches.length - MAX_LIST_ROWS} more — refine search` }));
    if (!matches.length)
      rows.push(el('div', { className: 'list-overflow', textContent: names.length ? 'no match' : 'nothing here' }));
    list.replaceChildren(...rows);
  }

  async function pick(field: string) {
    if (busy) return;
    if (parseItemKey(field)) {
      busy = true;
      root.classList.add('busy');
      status.classList.remove('error');
      status.textContent = 'reading…';
      try {
        await needItems([field]);
      } catch (e) {
        status.textContent = String((e as Error).message ?? e);
        status.classList.add('error');
        return;
      } finally {
        busy = false;
        root.classList.remove('busy');
      }
    }
    opts.onPick(field);
    closePicker();
  }

  // Below the button, kept on screen
  function place() {
    const a = opts.anchor.getBoundingClientRect();
    const w = root.offsetWidth, h = root.offsetHeight;
    root.style.left = `${Math.max(4, Math.min(a.left, innerWidth - w - 4))}px`;
    root.style.top = `${a.bottom + 4 + h > innerHeight ? Math.max(4, a.top - h - 4) : a.bottom + 4}px`;
  }

  const outside = (e: PointerEvent) => {
    const t = e.target as Node;
    if (!root.contains(t) && !opts.anchor.contains(t)) closePicker();
  };
  const keys = (e: KeyboardEvent) => {
    if (e.key === 'Escape') closePicker();
    else if (e.key === 'Enter' && document.activeElement === search)
      (list.querySelector('.picker-item') as HTMLElement | null)?.click();
  };
  document.addEventListener('pointerdown', outside, true);
  document.addEventListener('keydown', keys);
  addEventListener('resize', place);

  section.addEventListener('change', () => { search.value = ''; render(); search.focus(); });
  search.addEventListener('input', render);

  close = () => {
    close = null;
    document.removeEventListener('pointerdown', outside, true);
    document.removeEventListener('keydown', keys);
    removeEventListener('resize', place);
    root.remove();
  };

  options();
  render();
  place();
  search.focus();
  if (!state.manifest?.catalog) return;
  status.textContent = 'listing the object…';
  loadCatalog().then(srcs => {
    if (!root.isConnected) return;
    sources = srcs;
    status.textContent = '';
    const fresh = section.value === '' || section.value === META;
    options();
    if (fresh) startAt(opts.current);
    render();
    place();
  }, e => {
    if (!root.isConnected) return;
    status.textContent = String((e as Error).message ?? e);
    status.classList.add('error');
  });
}
