// The Analysis panel of launch_lens_analysis(): a menu of the included
// analyses, an Add analysis dialog over the catalog, a History menu per
// analysis, and one section per Giotto step with a menu per parameter, the
// step's status, its result tables and the cluster labels. Menus send
// `analysis_param`; in Preprocessing R reruns the step and those below it, in
// the other analyses the Run buttons send `analysis_run`. R sends
// `analysis_status` as each step finishes. Results arrive as metadata, panels
// and tables; a click on a gene in a table sends `analysis_feature`.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { onMessage, sendToR, isConnected } from '../core/comms.js';
import {
  emptyModel, applyParam, clusterRows, labelPayload, statusText, overall, numberKey, rangeText,
  rangeKey, sliderPos, sliderValue, clusterColorPatch, pipelines, pipelineSteps, canRun,
  tableRows, draftParams,
} from './analysis-model.ts';
import { PALETTE } from '../core/constants.js';

const model = emptyModel();
const mounted = new Set();          // render functions of open panels
const collapsed = new Set();        // step ids folded by the user
let activeTab = null;               // id of the analysis shown
let wantTab = null;                 // analysis to show once R has added it
let featureNote = null;             // { feat, column?, values?, error? }
const tableState = new Map();       // `${step}/${table}` -> { filter, sort, desc }
const TABLE_ROWS = 500;
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

const icon = name => { const i = el('i'); i.setAttribute('data-lucide', name); return i; };

function runButton(title, data, enabled) {
  const b = el('button', 'an-btn an-run');
  b.title = title;
  b.dataset.run = data.step ?? data.pipeline;
  b.append(icon('play'), document.createTextNode(data.step ? 'run' : 'run all'));
  b.disabled = !enabled || !isConnected();
  b.addEventListener('click', e => {
    e.stopPropagation();
    sendToR('analysis_run', data);
  });
  return b;
}

function stepSection(step, send, manual) {
  const st = model.status[step.id];
  const sec = el('div', `an-step an-${st?.status ?? 'stale'}`);
  sec.dataset.step = step.id;
  if (collapsed.has(step.id)) sec.classList.add('an-collapsed');

  const hd = el('div', 'an-step-hd');
  const chev = el('i'); chev.setAttribute('data-lucide', 'chevron-down'); chev.className = 'an-chev';
  hd.append(chev, el('span', 'an-step-label', step.label), el('span', 'an-fun', step.fun),
    el('span', 'an-badge', statusText(st)));
  if (manual) hd.append(runButton('run this step and the stale steps above it',
    { step: step.id }, canRun(model, step.id)));
  hd.addEventListener('click', () => {
    if (collapsed.has(step.id)) collapsed.delete(step.id); else collapsed.add(step.id);
    sec.classList.toggle('an-collapsed');
  });
  sec.append(hd);

  const body = el('div', 'an-step-body');
  for (const p of step.params) body.append(paramRow(step, p, send));
  if (st?.summary) body.append(el('div', 'an-summary', st.summary));
  for (const t of model.tables[step.id] ?? []) body.append(tableBlock(step.id, t));
  if (st?.status === 'error' && st.message) body.append(el('div', 'an-error', st.message));
  if (st?.status === 'blocked' && st.message) body.append(el('div', 'an-summary', st.message));
  if (step.id === 'labels') body.append(labelsBlock());
  sec.append(body);
  return sec;
}

// One parameter: a menu, or a slider with a number box
function paramRow(step, p, send) {
  const row = el('label', 'an-row');
  row.append(el('span', 'an-plabel', p.label));
  if (p.type === 'number' || p.type === 'range') {
    row.append(p.type === 'range' ? rangeBox(step, p, send) : numberBox(step, p, send));
    return row;
  }
  if (p.type === 'text') {
    const box = el('input', 'an-sel an-text');
    box.type = 'text'; box.spellcheck = false; box.value = p.value ?? '';
    box.placeholder = p.placeholder ?? '';
    box.dataset.param = p.id;
    box.addEventListener('change', () => send(step.id, p.id, box.value));
    box.addEventListener('keydown', e => { if (e.key === 'Enter') box.blur(); });
    row.append(box);
    return row;
  }
  const sel = el('select', 'an-sel');
  if (!p.choices.length) {
    sel.append(Object.assign(el('option', '', 'none available'), { value: '' }));
    sel.disabled = true;
  }
  for (const c of p.choices) {
    const o = el('option', '', c.label);
    o.value = c.value;
    sel.append(o);
  }
  sel.value = p.value;
  sel.dataset.param = p.id;
  sel.addEventListener('change', () => send(step.id, p.id, sel.value));
  row.append(sel);
  return row;
}

// A result table: filter, sort by a header click, a click on a gene row
// colors the cells by it
function tableBlock(stepId, t) {
  const key = `${stepId}/${t.id}`;
  if (!tableState.has(key)) tableState.set(key, { filter: '', sort: null, desc: true });
  const ts = tableState.get(key);
  const box = el('div', 'an-table');
  box.dataset.table = t.id;
  const hd = el('div', 'an-thd');
  hd.append(el('span', 'an-ttitle', t.title));
  const filter = el('input', 'an-sel an-tfilter');
  filter.type = 'text'; filter.placeholder = 'filter'; filter.spellcheck = false; filter.value = ts.filter;
  hd.append(filter);
  box.append(hd);
  if (t.note) box.append(el('div', 'an-note', t.note));
  const featIdx = t.feat ? t.columns.indexOf(t.feat) : -1;
  const wrap = el('div', 'an-twrap');
  const count = el('div', 'an-note');
  const fill = () => {
    const rows = tableRows(t, ts.filter, ts.sort, ts.desc);
    const tbl = el('table', 'an-tbl');
    const tr = el('tr');
    t.columns.forEach((c, i) => {
      const th = el('th', '', c + (ts.sort === i ? (ts.desc ? ' ▾' : ' ▴') : ''));
      th.addEventListener('click', () => {
        if (ts.sort === i) ts.desc = !ts.desc; else { ts.sort = i; ts.desc = true; }
        fill();
      });
      tr.append(th);
    });
    tbl.append(tr);
    for (const r of rows.slice(0, TABLE_ROWS)) {
      const row = el('tr');
      for (const v of r) row.append(el('td', '', v == null ? '' : String(v)));
      if (featIdx >= 0 && r[featIdx] != null) {
        row.classList.add('an-trow');
        row.title = `color cells by ${r[featIdx]}`;
        row.addEventListener('click', () => {
          featureNote = { feat: String(r[featIdx]), pending: true };
          sendToR('analysis_feature', { step: stepId, feat: String(r[featIdx]) });
          refresh();
        });
      }
      tbl.append(row);
    }
    wrap.replaceChildren(tbl);
    const of = t.n > t.shown ? ` (R sent ${t.shown.toLocaleString()} of ${t.n.toLocaleString()})` : '';
    count.textContent = `${Math.min(rows.length, TABLE_ROWS).toLocaleString()} of ` +
      `${rows.length.toLocaleString()} rows shown${of}`;
  };
  filter.addEventListener('input', () => { ts.filter = filter.value; fill(); });
  filter.addEventListener('keydown', e => { if (e.key === 'Enter') filter.blur(); });
  fill();
  box.append(wrap, count);
  return box;
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

// The included analyses, Add analysis, remove and History
function analysisBar(tabs) {
  const bar = el('div', 'an-settings an-anbar');
  bar.append(el('span', 'an-plabel', 'analysis'));
  const pick = el('select', 'an-sel an-anpick');
  for (const t of tabs) {
    const o = el('option', '', `${t.label} · ${overall(model, t.id)}`);
    o.value = t.id;
    pick.append(o);
  }
  pick.value = activeTab ?? '';
  pick.title = 'the analysis shown below';
  pick.addEventListener('change', () => { activeTab = pick.value; refresh(); });
  const add = el('button', 'an-btn an-add');
  add.title = 'choose an analysis to add';
  add.append(icon('plus'), document.createTextNode('add analysis'));
  add.disabled = !model.schema?.catalog?.length;
  add.addEventListener('click', () => openCatalog());
  const tab = tabs.find(t => t.id === activeTab);
  const del = el('button', 'an-btn an-remove');
  del.title = 'remove this analysis (its history is kept)';
  del.append(icon('trash-2'));
  del.disabled = !tab?.removable || !isConnected();
  del.addEventListener('click', () => {
    if (tab && confirm(`Remove ${tab.label}? Its results are kept under History if added again.`))
      sendToR('analysis_remove', { id: tab.id });
  });
  bar.append(pick, add, del);
  const runs = tab?.history ?? [];
  const hist = el('select', 'an-sel an-history');
  hist.append(Object.assign(el('option', '', runs.length ? `history (${runs.length})` : 'no history'),
    { value: '' }));
  for (const r of runs) {
    const o = el('option', '', `${r.current ? '● ' : ''}${r.time} · ${r.label || 'run ' + r.run}`);
    o.value = String(r.run);
    o.title = r.params.join('\n');
    hist.append(o);
  }
  hist.disabled = !runs.length || !isConnected();
  hist.title = 'bring back the parameters and results of an earlier run';
  hist.addEventListener('change', () => {
    if (hist.value) sendToR('analysis_history', { id: tab.id, run: Number(hist.value) });
  });
  const hrow = el('div', 'an-settings');
  hrow.append(el('span', 'an-plabel', 'history'), hist);
  const box = el('div');
  box.append(bar, hrow);
  return box;
}

// The Add analysis dialog: the catalog on the left; the chosen entry's
// description, inputs, outputs and steps (parameters editable) on the right
let catalogOpen = null;
function openCatalog() {
  catalogOpen?.remove();
  const cat = model.schema?.catalog ?? [];
  if (!cat.length) return;
  const bg = el('div', 'an-modal-bg');
  const dlg = el('div', 'an-modal');
  dlg.setAttribute('role', 'dialog');
  dlg.setAttribute('aria-label', 'Add analysis');
  bg.append(dlg);
  const close = () => { bg.remove(); catalogOpen = null; document.removeEventListener('keydown', onKey); };
  const onKey = e => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', onKey);
  bg.addEventListener('mousedown', e => { if (e.target === bg) close(); });
  const head = el('div', 'an-modal-hd');
  const x = el('button', 'tool-btn'); x.title = 'close'; x.append(icon('x'));
  x.addEventListener('click', close);
  head.append(el('span', 'an-title', 'Add analysis'), x);
  const list = el('div', 'an-cat-list');
  const detail = el('div', 'an-cat-detail');
  const main = el('div', 'an-modal-main');
  main.append(list, detail);
  dlg.append(head, main);
  const drafts = {};
  let chosen = cat.find(e => !e.included) ?? cat[0];
  const show = () => {
    list.replaceChildren();
    for (const e of cat) {
      const b = el('button', 'an-cat-item' + (e.id === chosen.id ? ' an-active' : ''));
      b.dataset.entry = e.id;
      b.append(el('span', 'an-cat-label', e.label), el('span', 'an-cat-brief', e.brief));
      if (e.included) b.append(el('span', 'an-badge', 'included'));
      b.addEventListener('click', () => { chosen = e; show(); });
      list.append(b);
    }
    const e = chosen;
    const copy = drafts[e.id] ??= { steps: structuredClone(e.steps), values: {} };
    detail.replaceChildren();
    detail.append(el('div', 'an-cat-title', e.label), el('div', 'an-cat-lead', e.brief),
      el('p', 'an-cat-desc', e.description));
    const lst = (title, items) => {
      const sec = el('div', 'an-cat-sec');
      sec.append(el('div', 'an-cat-h', title));
      const ul = el('ul');
      for (const it of items) ul.append(el('li', '', it));
      sec.append(ul);
      return sec;
    };
    detail.append(lst('Inputs', e.inputs), lst('Outputs', e.outputs));
    const steps = el('div', 'an-cat-sec');
    steps.append(el('div', 'an-cat-h', e.included ? 'Steps (edit them in the panel)' : 'Steps'));
    const send = (sid, pid, v) => {
      (copy.values[sid] ??= {})[pid] = v;
      const p = copy.steps.find(st => st.id === sid)?.params.find(q => q.id === pid);
      if (p) p.value = v;
    };
    copy.steps.forEach((st, i) => {
      const sec = el('div', 'an-step an-cat-step');
      const hd = el('div', 'an-step-hd');
      hd.append(el('span', 'an-step-label', `${i + 1}. ${st.label}`), el('span', 'an-fun', st.fun));
      sec.append(hd);
      const body = el('div', 'an-step-body');
      for (const p of st.params) {
        const row = paramRow(st, p, send);
        if (e.included) row.querySelectorAll('input,select').forEach(n => { n.disabled = true; });
        body.append(row);
      }
      if (!st.params.length) body.append(el('div', 'an-note', 'no parameters'));
      sec.append(body);
      steps.append(sec);
    });
    detail.append(steps);
    const foot = el('div', 'an-modal-ft');
    const cancel = el('button', 'an-btn', 'cancel');
    cancel.addEventListener('click', close);
    const go = el('button', 'an-btn an-primary', e.included ? 'show' : 'add');
    go.disabled = !isConnected() && !e.included;
    go.addEventListener('click', () => {
      if (!e.included) {
        const vals = Object.fromEntries(Object.entries(copy.values));
        const entry = { ...e, steps: e.steps };
        sendToR('analysis_add', { id: e.id, params: draftParams(entry, vals) });
      }
      wantTab = e.id;
      activeTab = e.included ? e.id : activeTab;
      close();
      refresh();
    });
    foot.append(cancel, go);
    detail.append(foot);
    createIcons({ icons, nodes: dlg.querySelectorAll('[data-lucide]') });
  };
  show();
  document.body.append(bg);
  catalogOpen = bg;
}

// A tab whose steps wait for Run
function runBar(tab) {
  const bar = el('div', 'an-settings an-runbar');
  const any = pipelineSteps(model, tab.id).some(s => canRun(model, s.id));
  bar.append(el('span', 'an-region', 'changes wait for Run'),
    runButton('run every stale step of this tab', { pipeline: tab.id }, any));
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
         focused?.classList?.contains('an-setname') || focused?.classList?.contains('an-tfilter') ||
         focused?.classList?.contains('an-text')) &&
        root.contains(focused)) return;
    const top = root.scrollTop;
    root.replaceChildren();
    const hd = el('div', 'an-hd');
    hd.append(el('span', 'an-title', 'Giotto analysis'), el('span', 'an-overall', overall(model)));
    const cancel = el('button', 'tool-btn an-cancel');
    cancel.title = 'cancel the running step and the steps waiting to run';
    const ic = el('i'); ic.setAttribute('data-lucide', 'square'); cancel.append(ic);
    cancel.disabled = !Object.values(model.status).some(s => s.status === 'running' || s.status === 'queued');
    cancel.addEventListener('click', () => sendToR('analysis_cancel', {}));
    hd.append(cancel);
    root.append(hd);
    if (!isConnected()) root.append(el('div', 'an-error an-offline',
      'R is not connected: changes are not run. If the viewer was closed or relaunched, ' +
      'open the URL R printed last.'));
    const tabs = pipelines(model);
    if (wantTab && tabs.some(t => t.id === wantTab)) { activeTab = wantTab; wantTab = null; }
    if (!tabs.some(t => t.id === activeTab)) activeTab = tabs[0]?.id ?? null;
    root.append(settingsBar());
    root.append(regionBar());
    root.append(analysisBar(tabs));
    if (featureNote) root.append(el('div', featureNote.error ? 'an-error' : 'an-note',
      featureNote.error ? `${featureNote.feat}: ${featureNote.error}`
        : featureNote.pending ? `getting ${featureNote.feat}…`
        : `cells colored by ${featureNote.feat} (${featureNote.values} expression, column ${featureNote.column})`));
    if (model.schema?.disk && activeTab === 'preprocess') root.append(el('div', 'an-note',
      'GiottoDisk expression: z-score scaling and non-standard normalization are not offered'));
    const tab = tabs.find(t => t.id === activeTab);
    if (tab && !tab.auto) root.append(runBar(tab));
    for (const s of tab ? pipelineSteps(model, tab.id) : [])
      root.append(stepSection(s, send, tab && !tab.auto));
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
  onMessage('analysis_tables', ({ tables }) => { model.tables = tables ?? {}; refresh(); });
  onMessage('analysis_feature', note => { featureNote = { ...note, pending: false }; refresh(); });
  onMessage('load_metadata', () => { applyColor(); syncClusterColors(); refresh(); });
  store.subscribe(s => s.categoryStyles.cell_type, syncClusterColors);
  store.subscribe(s => s.metaVersion, refresh);
}

// For tests and the browser console
export const analysisModel = () => model;
export const analysisUi = { openCatalog, get active() { return activeTab; } };
