// Preferences: lens_preferences() in the viewer, a dialog the tools bar's
// gear opens over the page, as its folder button does the project dialog
// (ui/start.ts). Sections and sub headings expand and collapse; a preference
// that was set is marked and has a reset button, the others show the
// built-in default. Changes go to R, which saves them and sends them back to
// every viewer (core/prefs.ts).
import { loadCatalog } from '../data/catalog.ts';
import { expressionValues } from '../panels/saved-model.ts';
import { sendToR } from '../core/comms.js';
import { prefs, prefDefaults, prefIsSet, onPrefs, type PrefName } from '../core/prefs.ts';
import { SCALE_PRESETS } from '../render/colors.ts';
import { CATEGORY_PALETTES } from '../core/constants.js';

type Kind = 'select' | 'palette' | 'catpal' | 'number' | 'range' | 'color' | 'text' | 'values';
interface Item { id: PrefName; label: string; kind: Kind; options?: string[]; min?: number; max?: number;
  step?: number; placeholder?: string; title?: string }
interface Group { title: string | null; items: Item[] }

const SECTIONS: { title: string; groups: Group[] }[] = [
  { title: 'Colors', groups: [
    { title: 'Page', items: [
      { id: 'theme', label: 'theme', kind: 'select', options: ['dark', 'light'],
        title: 'the panels and controls; the spatial view and scatter plots stay dark' },
    ] },
    { title: 'Continuous', items: [
      { id: 'seq_palette', label: 'sequential palette', kind: 'palette',
        options: ['viridis', 'magma', 'inferno', 'plasma', 'cividis', 'turbo', 'gray', 'blue-red'] },
      { id: 'div_palette', label: 'divergent palette', kind: 'palette',
        options: ['blue-white-red', 'RdBu', 'PuOr', 'PRGn'] },
      { id: 'scale_style', label: 'default style', kind: 'select', options: ['divergent', 'sequential'] },
      { id: 'gene_style', label: 'gene coloring', kind: 'select', options: ['default', 'divergent', 'sequential'],
        title: 'style of the color scale genes share; default: the default style' },
    ] },
    { title: 'Categories', items: [
      { id: 'cat_palette', label: 'category palette', kind: 'catpal', options: ['default', 'vivid', 'okabe_ito'] },
      { id: 'tx_palette', label: 'transcript palette', kind: 'select', options: ['default', 'vivid'] },
    ] },
    { title: 'Canvas', items: [
      { id: 'background', label: 'background', kind: 'color',
        title: 'color behind the cells; unset, the theme\'s' },
    ] },
  ] },
  { title: 'Cells', groups: [{ title: null, items: [
    { id: 'outline_color', label: 'outline color', kind: 'color' },
    { id: 'selection_color', label: 'selection color', kind: 'color' },
    { id: 'outline_width', label: 'outline width (px)', kind: 'number', min: 0, max: 10, step: 0.25 },
    { id: 'outline_opacity', label: 'outline opacity', kind: 'range', min: 0, max: 1, step: 0.05 },
    { id: 'fill_opacity', label: 'fill opacity', kind: 'range', min: 0, max: 1, step: 0.05 },
  ] }] },
  { title: 'Expression', groups: [{ title: null, items: [
    { id: 'expr_values', label: 'picker opens on', kind: 'values' },
    { id: 'de_values', label: 'comparison values', kind: 'values' },
    { id: 'color_by', label: 'color by at launch', kind: 'text', placeholder: 'e.g. cell_type, leiden_clus',
      title: 'the first of these metadata columns present colors the cells when a viewer starts' },
  ] }] },
  { title: 'Analysis', groups: [{ title: null, items: [
    { id: 'threads', label: 'background threads', kind: 'number', min: 1, max: 256, step: 1 },
    { id: 'history', label: 'runs kept in History', kind: 'number', min: 1, max: 1000, step: 1 },
    { id: 'network_dir', label: 'saved networks folder', kind: 'text', placeholder: 'GiottoLens user cache' },
  ] }] },
];

const ITEMS = SECTIONS.flatMap(s => s.groups.flatMap(g => g.items));
const open = new Set<string>(['Colors', 'Colors/Page', 'Colors/Continuous']);

const el = (tag: string, className = '', text = ''): HTMLElement =>
  Object.assign(document.createElement(tag), { className, textContent: text });
const rgb = (c: number[]) => `rgb(${c[0]},${c[1]},${c[2]})`;
const gradient = (name: string) =>
  `linear-gradient(90deg,${(SCALE_PRESETS[name] ?? []).map(rgb).join(',')})`;

const setPref = (id: PrefName, value: unknown) => sendToR('preferences_set', { set: { [id]: value } });
const resetPref = (ids: PrefName[] | true) => sendToR('preferences_set', { reset: ids });

function control(it: Item): HTMLElement {
  const p = prefs() as unknown as Record<string, unknown>;
  const def = prefDefaults() as unknown as Record<string, unknown>;
  const v = p[it.id];
  const changed = prefIsSet(it.id);
  const row = el('div', 'pref-row' + (changed ? ' pref-set' : ''));
  row.dataset.pref = it.id;
  const lab = el('label', '', it.label);
  lab.title = it.title ?? it.label;
  const box = el('div', 'pref-ctl');
  if (it.kind === 'select' || it.kind === 'palette' || it.kind === 'catpal') {
    const s = el('select', 'ctl-select') as HTMLSelectElement;
    for (const o of it.options!) s.append(new Option(o + (o === def[it.id] ? ' (default)' : ''), o));
    s.value = String(v);
    s.addEventListener('change', () => setPref(it.id, s.value));
    box.append(s);
    if (it.kind === 'palette') {
      const bar = el('div', 'pref-bar');
      bar.style.background = gradient(String(v));
      box.append(bar);
    }
    if (it.kind === 'catpal') {
      const sw = el('div', 'pref-swatches');
      for (const c of (CATEGORY_PALETTES as Record<string, number[][]>)[String(v)] ?? []) {
        const e = el('span');
        e.style.background = rgb(c);
        sw.append(e);
      }
      box.append(sw);
    }
  } else if (it.kind === 'number') {
    const i = el('input', 'ctl-input') as HTMLInputElement;
    Object.assign(i, { type: 'number', min: String(it.min), max: String(it.max), step: String(it.step ?? 1) });
    i.value = String(v);
    i.addEventListener('change', () => { if (i.value !== '' && Number.isFinite(+i.value)) setPref(it.id, +i.value); });
    box.append(i);
  } else if (it.kind === 'range') {
    const i = el('input', 'pref-range') as HTMLInputElement;
    Object.assign(i, { type: 'range', min: String(it.min), max: String(it.max), step: String(it.step) });
    i.value = String(v);
    const out = el('span', 'pref-val', String(v));
    i.addEventListener('input', () => { out.textContent = i.value; });
    i.addEventListener('change', () => setPref(it.id, +i.value));
    box.append(i, out);
  } else if (it.kind === 'color') {
    const i = el('input', 'pref-color') as HTMLInputElement;
    i.type = 'color';
    i.value = String(v);
    i.addEventListener('change', () => setPref(it.id, i.value));
    box.append(i);
  } else if (it.kind === 'text' || it.kind === 'values') {
    const i = el('input', 'ctl-input') as HTMLInputElement;
    i.type = 'text';
    i.value = String(v ?? '');
    i.placeholder = it.placeholder ?? '';
    if (it.kind === 'values') {
      const list = el('datalist') as HTMLDataListElement;
      list.id = `pref-list-${it.id}`;
      // The object's expression values, as the catalog lists them
      void loadCatalog().then(srcs => {
        for (const o of expressionValues(srcs)) list.append(new Option(o, o));
      }).catch(() => {});
      i.setAttribute('list', list.id);
      box.append(list);
    }
    i.addEventListener('change', () => {
      const t = i.value.trim();
      setPref(it.id, t);
    });
    box.append(i);
  }
  const rs = el('button', 'pref-reset', '↺') as HTMLButtonElement;
  rs.title = 'back to the default';
  rs.style.visibility = changed ? 'visible' : 'hidden';
  rs.addEventListener('click', () => resetPref([it.id]));
  row.append(lab, box, rs);
  return row;
}

function section(key: string, title: string, n: number, fill: (d: HTMLElement) => void, sub = false): HTMLElement {
  const d = el('details', sub ? 'pref-sub' : 'pref-sec') as HTMLDetailsElement;
  d.dataset.section = key;
  d.open = open.has(key);
  d.addEventListener('toggle', () => { if (d.open) open.add(key); else open.delete(key); });
  const s = el('summary');
  s.append(el('span', 'pref-title', title), el('span', 'pref-count', n ? `${n} set` : ''));
  d.append(s);
  fill(d);
  return d;
}

// lens_preferences() call for the preferences that were set
function rCode(): string {
  const p = prefs() as unknown as Record<string, unknown>;
  const set = ITEMS.filter(it => prefIsSet(it.id));
  if (!set.length) return 'lens_preferences()   # every preference at its default';
  const val = (x: unknown): string => typeof x === 'number' ? String(x)
    : typeof x === 'object' && x ? `c(${Object.entries(x).map(([k, c]) => `"${k}" = "${c}"`).join(', ')})`
    : JSON.stringify(x);
  return `lens_preferences(${set.map(it => `\n    ${it.id} = ${val(p[it.id])}`).join(',')})`;
}

// The preferences, in `body`; returns what stops them following changes
function buildPreferences(body: HTMLElement): () => void {
  const root = el('div', 'ctl-body pref-panel');
  const sections = el('div', 'pref-sections');
  const foot = el('div', 'pref-foot');
  const resetAll = el('button', '', 'reset all') as HTMLButtonElement;
  const showR = el('button', '', 'R code') as HTMLButtonElement;
  const code = el('pre', 'pref-code');
  code.hidden = true;
  resetAll.addEventListener('click', () => resetPref(true));
  showR.addEventListener('click', () => { code.hidden = !code.hidden; });
  const buttons = el('div', 'ctl-actions');
  buttons.append(resetAll, showR);
  foot.append(buttons, el('div', 'pref-note',
    'Only preferences that were set are saved; the others follow GiottoLens defaults.'), code);
  root.append(sections, foot);
  body.append(root);

  const draw = () => {
    sections.replaceChildren(...SECTIONS.map(sec => {
      const n = sec.groups.flatMap(g => g.items).filter(it => prefIsSet(it.id)).length;
      return section(sec.title, sec.title, n, d => {
        for (const g of sec.groups) {
          if (!g.title) {
            const b = el('div', 'pref-body');
            g.items.forEach(it => b.append(control(it)));
            d.append(b);
            continue;
          }
          const key = `${sec.title}/${g.title}`;
          d.append(section(key, g.title, g.items.filter(it => prefIsSet(it.id)).length, dd => {
            const b = el('div', 'pref-body');
            g.items.forEach(it => b.append(control(it)));
            dd.append(b);
          }, true));
        }
      });
    }));
    code.textContent = rCode();
  };
  draw();
  return onPrefs(() => draw());
}

// The tools bar's gear: the preferences in a dialog over the page, closed by
// its ×, a click outside it or Escape
export function initPreferencesButton(btn: HTMLElement, signal?: AbortSignal) {
  let overlay: HTMLElement | null = null;
  let stop = () => {};
  const close = () => {
    stop();
    overlay?.remove();
    overlay = null;
    btn.classList.remove('active');
  };
  btn.addEventListener('click', () => {
    if (overlay) { close(); return; }
    overlay = el('div', 'start-overlay');
    overlay.addEventListener('mousedown', ev => { if (ev.target === overlay) close(); });
    const box = el('div', 'start pref-dialog');
    const x = el('button', 'start-close', '\u00d7') as HTMLButtonElement;
    x.title = 'close';
    x.addEventListener('click', close);
    const body = el('div', 'pref-dialog-body');
    box.append(x, el('div', 'start-title', 'Preferences'), body);
    overlay.append(box);
    stop = buildPreferences(body);
    document.body.append(overlay);
    btn.classList.add('active');
  });
  window.addEventListener('keydown', ev => { if (ev.key === 'Escape' && overlay) close(); }, { signal });
  signal?.addEventListener('abort', close);
}

// For tests
export const preferenceIds = (): PrefName[] => ITEMS.map(it => it.id);
