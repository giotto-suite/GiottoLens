// The table's filter button: a popover that sets the metadata filter, the
// page's `meta` rule (filterMeta() in selection/selection.ts). It is a rule
// of its own, apart from the table's picked rows, so it narrows the table's
// rows and the picks select among them. Every table's button shows the same
// filter.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { filterMeta } from '../selection/selection.ts';
// @ts-ignore: plain JS module
import { ruleLabel } from '../ui/rules.js';

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

const OPS: [string, string][] = [['=', '='], ['!=', '≠'], ['>', '>'], ['<', '<'], ['contains', 'contains']];

// The button, for the table's bar, and what removes its popover
export function filterButton(): { button: HTMLButtonElement; destroy(): void } {
  const button = el('button', { className: 'table-filter', title: 'filter the cells by metadata' });
  button.innerHTML = '<i data-lucide="funnel"></i><span>filter</span>';
  createIcons({ icons, root: button });

  const form = el('div', { className: 'meta-sel-panel table-filter-panel' });
  const now = el('div', { className: 'filter-now' });
  const col = el('select', { className: 'filter-col' });
  const op  = el('select', { className: 'filter-op' });
  op.append(...OPS.map(([value, textContent]) => el('option', { value, textContent })));
  const val = el('input', { className: 'filter-val', type: 'text', placeholder: 'value…',
    autocomplete: 'off', spellcheck: false });
  const replace = el('button', { className: 'meta-sel-apply filter-replace', textContent: 'replace',
    title: 'filter by this condition only' });
  const add = el('button', { className: 'meta-sel-apply filter-add', textContent: 'add',
    title: 'add this condition to the filter: cells must meet every one' });
  const clear = el('button', { className: 'filter-clear', textContent: 'clear filter' });
  const note = el('div', { className: 'filter-note' });
  const row = (...kids: HTMLElement[]) => {
    const r = el('div', { className: 'meta-sel-row' });
    r.append(...kids);
    return r;
  };
  form.append(now, row(col, op), row(val), row(replace, add, clear), note);
  document.body.append(form);

  const fillColumns = () => {
    const names = state.metaInfo ? [...state.metaInfo.keys()] as string[] : [];
    const keep = col.value;
    col.replaceChildren(...(names.length ? names.map(n => el('option', { value: n, textContent: n }))
      : [el('option', { value: '', textContent: 'no metadata loaded' })]));
    if (names.includes(keep)) col.value = keep;
    replace.disabled = add.disabled = !names.length;
  };
  // What the filter is now, and what it does in OR mode
  const sync = () => {
    const s = store.getState(), rule = s.rules.meta;
    button.classList.toggle('active', !!rule);
    now.textContent = rule ? ruleLabel(rule) : 'no filter';
    now.classList.toggle('none', !rule);
    add.disabled = replace.disabled || !rule;
    clear.disabled = !rule;
    note.textContent = s.combine === 'or' ? 'or mode: the filter adds to the selection' : '';
  };
  const offRules = store.subscribe(s => s.rules.meta, sync);
  const offCombine = store.subscribe(s => s.combine, sync);

  const apply = (mode: 'replace' | 'add') => {
    if (!col.value || !state.metaInfo?.has(col.value)) return;
    filterMeta(col.value, op.value as Parameters<typeof filterMeta>[1], val.value, mode);
  };
  replace.addEventListener('click', () => apply('replace'));
  add.addEventListener('click', () => apply('add'));
  val.addEventListener('keydown', e => { if (e.key === 'Enter') apply(store.getState().rules.meta ? 'add' : 'replace'); });
  clear.addEventListener('click', () => actions.setRule('meta', null));

  const close = () => { form.classList.remove('visible'); button.classList.remove('open'); };
  button.addEventListener('click', e => {
    e.stopPropagation();
    if (form.classList.contains('visible')) { close(); return; }
    fillColumns();
    sync();
    const r = button.getBoundingClientRect();
    Object.assign(form.style, { left: `${r.left}px`, top: `${r.bottom + 4}px` });
    form.classList.add('visible');
    button.classList.add('open');
    val.focus();
  });
  form.addEventListener('click', e => e.stopPropagation());
  const off = new AbortController();
  document.addEventListener('click', close, { signal: off.signal });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') close(); }, { signal: off.signal });
  fillColumns();
  sync();

  return { button, destroy() { off.abort(); offRules(); offCombine(); form.remove(); } };
}
