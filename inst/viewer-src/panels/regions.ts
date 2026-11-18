// The Regions panel: named sets of cells saved from the selection, and
// differential expression between two of them or one and every other cell
// (adr/0020). R holds the regions and sends them as `regions`; the panel acts
// through the `region` ask. A comparison is a job (adr/0025): its ask is
// answered when the job ends, and the job carries the panel's `ref`, by which
// the panel finds it to cancel it. Results arrive as pushed volcano panels.
// viewer$save_region(), compare_regions(), ... are the same from R.
import { store } from '../core/store.ts';
// @ts-ignore: plain JS module
import { askR, onMessage, onConnect } from '../core/comms.js';
import type { PanelHandle } from './dock.ts';
import { loadCatalog } from '../data/catalog.ts';
import { onJobs, runningJobs } from '../ui/jobs.ts';
import {
  readRegions, nextName, compareTargets, expressionValues, compareBlocked, keepChoice, REST,
  type Region, type RegionsMsg,
} from './regions-model.ts';

let regions: Region[] = [];
const mounted = new Set<() => void>();

// Before initComms(), like every handler. `show` brings the panel forward,
// when R saves a region (`open`)
export function initRegions(show: () => void) {
  onMessage('regions', (msg: RegionsMsg) => {
    regions = readRegions(msg);
    if (msg.open) show();
    mounted.forEach(fn => fn());
  });
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text = ''): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), { className, textContent: text });

export function createRegionsPanel(body: HTMLElement): PanelHandle {
  const root = el('div', 'rg');
  body.append(root);
  let a = '', b = REST, values: string[] = [], chosen = '';
  let comparing: string | null = null;   // the running comparison's ref
  let destroyed = false;

  const name = el('input', 'rg-name');
  Object.assign(name, { type: 'text', spellcheck: false, autocomplete: 'off' });
  const save = el('button', 'rg-btn rg-save', 'save selection');
  save.title = 'save the selected cells as a region';
  const list = el('div', 'rg-list');
  const selA = el('select', 'rg-sel rg-a');
  const selB = el('select', 'rg-sel rg-b');
  const selV = el('select', 'rg-sel rg-values');
  selV.title = 'expression values the test reads';
  const run = el('button', 'rg-btn rg-compare', 'compare');
  run.title = 'differential expression, A vs B (scran t-test)';
  const note = el('div', 'rg-note');
  const status = el('div', 'rg-status');
  const saveRow = el('div', 'rg-row');
  saveRow.append(name, save);
  const cmpRow = el('div', 'rg-row');
  cmpRow.append(el('span', 'rg-lbl', 'A'), selA, el('span', 'rg-lbl', 'vs'), selB);
  const valRow = el('div', 'rg-row');
  valRow.append(el('span', 'rg-lbl', 'values'), selV, run);
  root.append(el('div', 'rg-hd', 'Regions'), saveRow, list,
    el('div', 'rg-hd', 'Differential expression'), cmpRow, valRow, note, status);

  const say = (text: string, kind: 'none' | 'running' | 'error' = 'none') => {
    status.textContent = text;
    status.className = `rg-status rg-${kind}`;
  };
  const act = (args: object) => askR('region', args).catch((e: Error) => say(String(e.message ?? e), 'error'));

  function doSave() {
    const n = name.value.trim() || nextName(regions);
    name.value = '';
    void act({ action: 'save', name: n }).then(r => { if (r) say(`saved '${n}'`); });
  }
  save.addEventListener('click', doSave);
  name.addEventListener('keydown', e => { if (e.key === 'Enter' && !save.disabled) doSave(); });
  selA.addEventListener('change', () => { a = selA.value; render(); });
  selB.addEventListener('change', () => { b = selB.value; render(); });
  selV.addEventListener('change', () => { chosen = selV.value; });

  const compareJob = () => runningJobs().find(j => j.ref === comparing)?.id;
  run.addEventListener('click', async () => {
    if (comparing) {
      const id = compareJob();
      if (id != null) void askR('cancel_job', { id }).catch(() => {});
      return;
    }
    if (compareBlocked(regions, values, a, b)) return;
    const ref = comparing = `de-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const what = `${a} vs ${b === REST ? 'rest' : b}`;
    say(`testing ${what}…`, 'running');
    render();
    try {
      await askR('region', { action: 'compare', a, b, values: chosen, ref });
      say(`${what}: done`);
    } catch (e) {
      const cancelled = (e as { code?: string }).code === 'cancelled';
      say(cancelled ? 'cancelled' : `${what}: ${(e as Error).message ?? e}`, cancelled ? 'none' : 'error');
    } finally {
      comparing = null;
      render();
    }
  });

  const fill = (sel: HTMLSelectElement, choices: { value: string; label: string }[], value: string) => {
    sel.replaceChildren(...choices.map(c => Object.assign(el('option', '', c.label), { value: c.value })));
    sel.value = value;
  };

  function render() {
    name.placeholder = nextName(regions);
    save.disabled = store.getState().selection.count === 0;
    list.replaceChildren(...regions.map(r => {
      const row = el('div', 'rg-item');
      row.dataset.region = r.name;
      const pick = el('button', 'rg-pick', r.name);
      pick.title = 'select these cells';
      pick.addEventListener('click', () => void act({ action: 'select', name: r.name }));
      const del = el('button', 'rg-del', '×');
      del.title = 'remove the region';
      del.addEventListener('click', () => void act({ action: 'remove', name: r.name }));
      row.append(pick, el('span', 'rg-n', `${r.n.toLocaleString()} cells`), del);
      return row;
    }));
    if (!regions.length)
      list.append(el('div', 'rg-empty', 'Select cells (lasso, polygon, a cluster, ...) and save them as a region.'));

    a = keepChoice(a, regions.map(r => r.name));
    fill(selA, regions.map(r => ({ value: r.name, label: r.name })), a);
    const targets = compareTargets(regions, a);
    b = keepChoice(b, targets.map(t => t.value));
    fill(selB, targets, b);
    chosen = keepChoice(chosen, values);
    fill(selV, values.map(v => ({ value: v, label: v })), chosen);
    selV.disabled = !values.length || !!comparing;

    const blocked = compareBlocked(regions, values, a, b);
    run.textContent = comparing ? 'cancel' : 'compare';
    run.disabled = comparing ? compareJob() == null : !!blocked;
    note.textContent = comparing ? '' : blocked ?? '';
  }

  async function loadValues() {
    try {
      values = expressionValues(await loadCatalog());
    } catch { values = []; }
    if (!destroyed) render();
  }

  mounted.add(render);
  const unsub = store.subscribe(s => s.selection.count, render);
  // The cancel button needs the comparison's job, which R reports as it starts
  const offJobs = onJobs(() => { if (comparing) render(); });
  const offConnect = onConnect(() => { if (!values.length) void loadValues(); });
  render();
  void loadValues();
  return {
    show: render,
    destroy() { destroyed = true; mounted.delete(render); unsub(); offJobs(); offConnect?.(); root.remove(); },
  };
}

// For tests and the browser console
export const regionList = () => regions;
