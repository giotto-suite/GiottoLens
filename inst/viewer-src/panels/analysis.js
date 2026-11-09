// The Analysis panel of launch_lens_analysis(): one section per Giotto step
// with a menu per parameter, the step's status, and the cluster labels.
// Menus send `analysis_param`; R reruns the step and those below it and sends
// `analysis_status` as each finishes. Results arrive as metadata and panels.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { onMessage, sendToR, isConnected } from '../core/comms.js';
import {
  emptyModel, applyParam, clusterRows, labelPayload, statusText, overall, numberKey, rangeText,
  rangeKey, sliderPos, sliderValue, clusterColorPatch,
} from './analysis-model.ts';
import { PALETTE } from '../core/constants.js';

const model = emptyModel();
const mounted = new Set();          // render functions of open panels
const collapsed = new Set();        // step ids folded by the user
let ensurePanel = () => {};

const el = (tag, className = '', text = '') =>
  Object.assign(document.createElement(tag), { className, textContent: text });

function refresh() { for (const r of mounted) r(); }

// Clusters with the same label share that label's cell type color
let shareColors = true;
let autoColors = {};
function syncClusterColors() {
  const cl = state.meta?.get('leiden_clus'), ty = state.meta?.get('cell_type');
  if (!cl || cl.kind !== 'categorical') return;
  const styles = store.getState().categoryStyles;
  const { patch, auto } = clusterColorPatch(shareColors ? model.labels : {},
    cl.levels ?? [], ty?.levels ?? [], styles.cell_type ?? {}, styles.leiden_clus ?? {},
    PALETTE, autoColors);
  autoColors = auto;
  if (Object.keys(patch).length) actions.setCategoryStyles('leiden_clus', patch);
}

function stepSection(step, send) {
  const st = model.status[step.id];
  const sec = el('div', `an-step an-${st?.status ?? 'stale'}`);
  sec.dataset.step = step.id;
  if (collapsed.has(step.id)) sec.classList.add('an-collapsed');

  const hd = el('div', 'an-step-hd');
  const chev = el('i'); chev.setAttribute('data-lucide', 'chevron-down'); chev.className = 'an-chev';
  hd.append(chev, el('span', 'an-step-label', step.label), el('span', 'an-fun', step.fun),
    el('span', 'an-badge', statusText(st)));
  hd.addEventListener('click', () => {
    if (collapsed.has(step.id)) collapsed.delete(step.id); else collapsed.add(step.id);
    sec.classList.toggle('an-collapsed');
  });
  sec.append(hd);

  const body = el('div', 'an-step-body');
  for (const p of step.params) {
    const row = el('label', 'an-row');
    row.append(el('span', 'an-plabel', p.label));
    if (p.type === 'number' || p.type === 'range') {
      row.append(p.type === 'range' ? rangeBox(step, p, send) : numberBox(step, p, send));
      body.append(row);
      continue;
    }
    const sel = el('select', 'an-sel');
    for (const c of p.choices) {
      const o = el('option', '', c.label);
      o.value = c.value;
      sel.append(o);
    }
    sel.value = p.value;
    sel.dataset.param = p.id;
    sel.addEventListener('change', () => send(step.id, p.id, sel.value));
    row.append(sel);
    body.append(row);
  }
  if (st?.summary) body.append(el('div', 'an-summary', st.summary));
  if (st?.status === 'error' && st.message) body.append(el('div', 'an-error', st.message));
  if (st?.status === 'blocked' && st.message) body.append(el('div', 'an-summary', st.message));
  if (step.id === 'labels') body.append(labelsBlock());
  sec.append(body);
  return sec;
}

// A slider with an editable number, as for cell outlines. The box takes any
// valid value, also beyond the slider's range; R reruns on release or Enter.
function numberBox(step, p, send) {
  const wrap = el('span', 'an-numwrap');
  const s = p.slider ?? { min: p.min ?? 0, max: (p.min ?? 0) + 100 };
  const slider = el('input', 'an-slider');
  slider.type = 'range';
  slider.min = String(sliderPos(s, s.min));
  slider.max = String(sliderPos(s, s.max));
  slider.step = s.log ? '0.01' : String(s.step ?? 'any');
  const box = el('input', 'an-sel an-num');
  box.type = 'text'; box.inputMode = 'decimal'; box.spellcheck = false;
  box.title = rangeText(p);
  box.dataset.param = p.id;
  let auto = null;
  const sync = () => {
    const isAuto = p.value === 'auto';
    box.value = isAuto ? '' : p.value;
    box.disabled = isAuto;
    slider.disabled = isAuto;
    if (!isAuto) slider.value = String(sliderPos(s, Number(p.value)));
    if (auto) auto.checked = isAuto;
  };
  const commit = raw => {
    const key = numberKey(p, raw);
    box.classList.toggle('an-invalid', key == null);
    if (key != null) send(step.id, p.id, key);
  };
  slider.addEventListener('input', () => {
    box.value = String(sliderValue(s, Number(slider.value), p.integer));
    box.classList.remove('an-invalid');
  });
  slider.addEventListener('change', () => commit(box.value));
  box.addEventListener('input', () => box.classList.toggle('an-invalid', numberKey(p, box.value) == null));
  box.addEventListener('change', () => commit(box.value));
  box.addEventListener('keydown', e => { if (e.key === 'Enter') box.blur(); });
  wrap.append(slider, box);
  if (p.auto) {
    const lab = el('label', 'an-auto');
    auto = el('input');
    auto.type = 'checkbox';
    auto.title = 'let Giotto choose';
    auto.addEventListener('change', () => {
      if (auto.checked) send(step.id, p.id, 'auto');
      else commit(String(sliderValue(s, Number(slider.value), p.integer)));
    });
    lab.append(auto, document.createTextNode('auto'));
    wrap.append(lab);
  }
  sync();
  return wrap;
}

// PCs from:to: a two-handled slider and two boxes
function rangeBox(step, p, send) {
  const wrap = el('span', 'an-numwrap an-rangewrap');
  const [lo0, hi0] = p.value.split(':').map(Number);
  const top = Math.max(p.max ?? p.slider?.max ?? 30, hi0);
  const dual = el('span', 'an-dual');
  const mk = v => {
    const r = el('input', 'an-slider');
    r.type = 'range'; r.min = String(p.min ?? 1); r.max = String(top); r.step = '1';
    r.value = String(v);
    return r;
  };
  const a = mk(lo0), b = mk(hi0);
  dual.append(a, b);
  const box = v => {
    const x = el('input', 'an-sel an-num an-pc');
    x.type = 'text'; x.inputMode = 'numeric'; x.spellcheck = false; x.value = String(v);
    return x;
  };
  const from = box(lo0), to = box(hi0);
  from.dataset.param = `${p.id}:from`;
  to.dataset.param = `${p.id}:to`;
  wrap.dataset.param = p.id;
  wrap.title = `PCs from:to, at most PC ${p.max ?? '?'}`;
  const key = () => rangeKey(p, `${from.value}:${to.value}`);
  const mark = () => {
    const bad = key() == null;
    from.classList.toggle('an-invalid', bad);
    to.classList.toggle('an-invalid', bad);
  };
  const commit = () => { const k = key(); mark(); if (k) send(step.id, p.id, k); };
  a.addEventListener('input', () => {
    if (Number(a.value) >= Number(b.value)) a.value = String(Number(b.value) - 1);
    from.value = a.value; mark();
  });
  b.addEventListener('input', () => {
    if (Number(b.value) <= Number(a.value)) b.value = String(Number(a.value) + 1);
    to.value = b.value; mark();
  });
  for (const r of [a, b]) r.addEventListener('change', commit);
  for (const x of [from, to]) {
    x.addEventListener('input', mark);
    x.addEventListener('change', () => {
      if (key()) { a.value = from.value; b.value = to.value; }
      commit();
    });
    x.addEventListener('keydown', e => { if (e.key === 'Enter') x.blur(); });
  }
  wrap.append(dual, from, el('span', 'an-dash', '–'), to);
  return wrap;
}

let labelTimer = null;
function labelsBlock() {
  const box = el('div', 'an-labels');
  const share = el('label', 'an-auto an-share');
  const cb = el('input');
  cb.type = 'checkbox';
  cb.checked = shareColors;
  cb.addEventListener('change', () => { shareColors = cb.checked; syncClusterColors(); });
  share.title = 'color clusters with the same label alike when coloring by leiden_clus';
  share.append(cb, document.createTextNode('clusters share their cell-type color'));
  box.append(share);
  const rows = clusterRows(model);
  if (!rows.length) { box.append(el('div', 'an-summary', 'labels appear once markers are found')); return box; }
  const legend = state.colorLegend?.type === 'categorical' && state.colorLegend.column === 'leiden_clus'
    ? state.colorLegend : null;
  for (const r of rows) {
    const row = el('div', 'an-lrow');
    const sw = el('span', 'an-swatch');
    const rgb = legend?.items.find(it => it.label === r.cluster)?.color;
    if (rgb) sw.style.background = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
    const inp = el('input', 'an-linput');
    inp.type = 'text'; inp.placeholder = `cluster ${r.cluster}`; inp.value = r.label;
    inp.spellcheck = false; inp.dataset.cluster = r.cluster;
    if (r.inherited) {
      inp.classList.add('an-inherited');
      inp.title = `carried over from cluster ${r.inherited.from} of the previous clustering ` +
        `(${Math.round(r.inherited.share * 100)}% of these cells); edit to confirm or change`;
    } else if (r.suggested && r.suggestion) {
      inp.classList.add('an-suggested');
      inp.title = `suggested from marker genes: ${Math.round(r.suggestion.share * 100)}% of ` +
        `these cells score highest for ${r.suggestion.type}; edit to confirm or change`;
    }
    inp.addEventListener('input', () => {
      model.labels[r.cluster] = inp.value;
      syncClusterColors();
      delete model.inherited[r.cluster];
      delete model.suggested[r.cluster];
      inp.classList.remove('an-inherited', 'an-suggested');
      clearTimeout(labelTimer);
      labelTimer = setTimeout(() => sendToR('analysis_labels', { labels: labelPayload(model.labels) }), 600);
    });
    inp.addEventListener('keydown', e => { if (e.key === 'Enter') inp.blur(); });
    row.append(sw, el('span', 'an-cl', r.cluster), inp);
    if (r.suggestion && !r.suggested && r.suggestion.type !== r.label) {
      const hint = el('button', 'an-hint' + (r.suggestion.share < 0.5 ? ' an-weak' : ''),
        `${r.suggestion.type} ${Math.round(r.suggestion.share * 100)}%`);
      hint.title = 'suggested from marker genes; click to use it';
      hint.addEventListener('click', e => {
        e.preventDefault();
        model.labels[r.cluster] = r.suggestion.type;
        sendToR('analysis_labels', { labels: labelPayload(model.labels) });
        refresh();
      });
      row.append(hint);
    } else if (r.suggested && r.suggestion?.share < 0.5) {
      inp.classList.add('an-weak');
    }
    row.append(el('span', 'an-feats', r.feats.join(' ')));
    box.append(row);
  }
  return box;
}

// The region the steps run on: the cells selected in the view, or all
function regionBar() {
  const bar = el('div', 'an-settings');
  const n = model.schema?.region ?? 0;
  bar.append(el('span', 'an-plabel', 'region'),
    el('span', 'an-region', n ? `${n.toLocaleString()} selected cells` : 'whole tissue'));
  const sel = el('button', 'an-btn', 'analyze selection');
  sel.title = 'run every step on the cells selected in the view (lasso, polygon or rectangle)';
  sel.addEventListener('click', () => sendToR('analysis_region', { action: 'selection' }));
  const all = el('button', 'an-btn', 'whole tissue');
  all.disabled = !n;
  all.addEventListener('click', () => sendToR('analysis_region', { action: 'all' }));
  bar.append(sel, all);
  return bar;
}

// Saved settings: save the current ones under a name, restore or remove one
function settingsBar() {
  const bar = el('div', 'an-settings');
  bar.append(el('span', 'an-plabel', 'saved settings'));
  const name = el('input', 'an-sel an-setname');
  name.type = 'text'; name.placeholder = 'name'; name.spellcheck = false;
  const save = el('button', 'an-btn', 'save');
  save.title = 'save the current parameters, marker list and labels';
  const doSave = () => {
    const n = name.value.trim();
    if (!n) { name.focus(); return; }
    sendToR('analysis_settings', { action: 'save', name: n });
    name.value = '';
  };
  save.addEventListener('click', doSave);
  name.addEventListener('keydown', e => { if (e.key === 'Enter') doSave(); });
  const sets = model.schema?.settings ?? [];
  const pick = el('select', 'an-sel an-setpick');
  pick.append(Object.assign(el('option', '', sets.length ? 'restore…' : 'none saved'), { value: '' }));
  for (const st of sets) {
    const o = el('option', '', `${st.name} (${st.time})`);
    o.value = st.name;
    pick.append(o);
  }
  pick.disabled = !sets.length;
  pick.title = 'go back to saved settings';
  pick.addEventListener('change', () => {
    if (pick.value) sendToR('analysis_settings', { action: 'restore', name: pick.value });
  });
  const del = el('button', 'an-btn', 'delete');
  del.title = 'delete the saved settings chosen in the menu';
  del.disabled = !sets.length;
  del.addEventListener('click', () => {
    const n = pick.value || (sets.length === 1 ? sets[0].name : '');
    if (n) sendToR('analysis_settings', { action: 'remove', name: n });
  });
  bar.append(name, save, pick, del);
  return bar;
}

// Fill `body` with the panel; it follows the model until destroyed
export function createAnalysisPanel(body, ctx) {
  const root = el('div', 'an-root');
  body.append(root);
  const send = (step, param, value) => {
    if (applyParam(model, step, param, value)) sendToR('analysis_param', { step, param, value });
    refresh();
  };
  const render = () => {
    // Keep the focused label box while typing
    const focused = document.activeElement;
    if ((focused?.classList?.contains('an-linput') || focused?.classList?.contains('an-num') ||
         focused?.classList?.contains('an-setname')) &&
        root.contains(focused)) return;
    const top = root.scrollTop;
    root.replaceChildren();
    const hd = el('div', 'an-hd');
    hd.append(el('span', 'an-title', 'Giotto analysis'), el('span', 'an-overall', overall(model)));
    const cancel = el('button', 'tool-btn an-cancel');
    cancel.title = 'cancel the running step';
    const ic = el('i'); ic.setAttribute('data-lucide', 'square'); cancel.append(ic);
    cancel.disabled = !Object.values(model.status).some(s => s.status === 'running');
    cancel.addEventListener('click', () => sendToR('analysis_cancel', {}));
    hd.append(cancel);
    root.append(hd);
    if (!isConnected()) root.append(el('div', 'an-error an-offline',
      'R is not connected: changes are not run. If the viewer was closed or relaunched, ' +
      'open the URL R printed last.'));
    root.append(settingsBar());
    root.append(regionBar());
    if (model.schema?.disk) root.append(el('div', 'an-note',
      'GiottoDisk expression: z-score scaling and non-standard normalization are not offered'));
    for (const s of model.schema?.steps ?? []) root.append(stepSection(s, send));
    createIcons({ icons, nodes: root.querySelectorAll('[data-lucide]') });
    root.scrollTop = top;
    ctx?.setTitle?.(`analysis · ${overall(model)}`);
  };
  mounted.add(render);
  render();
  return { destroy() { mounted.delete(render); root.remove(); }, show: render };
}

// Applied once the column has arrived with the metadata
let colorWanted = null;
function applyColor() {
  if (colorWanted && state.meta?.has(colorWanted)) {
    actions.setColorBy(colorWanted);
    colorWanted = null;
    refresh();
  }
}

// `place()` adds the dock panel; called when the first schema arrives
export function initAnalysis({ place }) {
  ensurePanel = place;
  let online = null;
  setInterval(() => {
    const now = isConnected();
    if (now !== online) { online = now; if (model.schema) refresh(); }
  }, 1000);
  onMessage('analysis_schema', schema => {
    model.schema = schema;
    ensurePanel();
    refresh();
  });
  onMessage('analysis_status', ({ steps }) => {
    model.status = steps ?? {};
    refresh();
  });
  onMessage('analysis_markers', ({ markers, labels, inherited, suggested, suggestions }) => {
    model.markers = markers ?? [];
    model.labels = { ...(labels ?? {}) };
    model.inherited = { ...(inherited ?? {}) };
    model.suggested = { ...(suggested ?? {}) };
    model.suggestions = suggestions ?? [];
    syncClusterColors();
    refresh();
  });
  onMessage('analysis_color', ({ column }) => { colorWanted = column; applyColor(); });
  onMessage('load_metadata', () => { applyColor(); syncClusterColors(); refresh(); });
  store.subscribe(s => s.categoryStyles.cell_type, syncClusterColors);
  store.subscribe(s => s.metaVersion, refresh);
}

// For tests and the browser console
export const analysisModel = () => model;
