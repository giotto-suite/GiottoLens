// The tools bar (adr/0023): the page's own controls, in a dock panel that
// starts as a narrow column at the page's left edge. As with an image
// editor's tool panel it is a column of icons, two when widened, and moves by
// its grip (the tab). It holds the actions on the page's selection; the
// count and the rules are the selection bar's (ui/selbar.js), and the tools
// that act in one view stay in that view.
import { createIcons, icons } from 'lucide';
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { invertSelection, filterMeta } from '../selection/selection.ts';
// @ts-ignore: plain JS module
import { escapeHtml } from '../ui/dom.js';
import { initProjectButton } from '../ui/start.ts';
import { jobsButton } from '../ui/jobs.ts';
import { initPreferencesButton } from '../ui/preferences.ts';
import { askR } from '../core/comms.js';
import { togglePanels, panelsShown, onLayoutChange, openAddMenu, type PanelHandle } from './dock.ts';

export function createToolsPanel(body: HTMLElement): PanelHandle {
  const off = new AbortController();
  const bar = document.createElement('div');
  bar.className = 'tools-bar';
  bar.innerHTML = `
    <button class="tool-btn" data-act="project" title="project: open a save, a snapshot or another project"><i data-lucide="folder-open"></i></button>
    <button class="tool-btn" data-act="save" title="save the work in the viewer (viewer$save())"><i data-lucide="save"></i></button>
    <button class="tool-btn" data-act="panels" title="show or hide the panels beside the spatial view"><i data-lucide="bar-chart-2"></i></button>
    <button class="tool-btn" data-act="add" title="add a panel"><i data-lucide="plus"></i></button>
    <button class="tool-btn jobs-btn" data-act="jobs" title="jobs"><i data-lucide="activity"></i></button>
    <button class="tool-btn" data-act="preferences" title="preferences: defaults for every viewer"><i data-lucide="settings"></i></button>
    <span class="tools-sep"></span>
    <button class="tool-btn" data-act="crossfilter" title="cross-filter mode (spatial ∩ scatter)"><i data-lucide="filter"></i></button>
    <button class="tool-btn" data-act="meta" title="select by metadata"><i data-lucide="text-search"></i></button>
    <button class="tool-btn" data-act="invert" title="invert selection"><i data-lucide="flip-horizontal-2"></i></button>
    <button class="tool-btn" data-act="clear" title="clear selection (C)"><i data-lucide="circle-x"></i></button>`;
  body.append(bar);
  createIcons({ icons, root: bar });

  initProjectButton(bar.querySelector('[data-act=project]') as HTMLElement, off.signal);
  initPreferencesButton(bar.querySelector('[data-act=preferences]') as HTMLElement, off.signal);
  const panels = bar.querySelector('[data-act=panels]') as HTMLElement;
  const showState = () => panels.classList.toggle('active', panelsShown());
  panels.addEventListener('click', () => { togglePanels(); showState(); });
  const offLayout = onLayoutChange(showState);
  const add = bar.querySelector('[data-act=add]') as HTMLElement;
  add.addEventListener('click', () => openAddMenu(add));
  showState();
  // Jobs R runs for the page, and cancelling them (ui/jobs.ts)
  const offJobs = jobsButton(bar.querySelector('[data-act=jobs]') as HTMLElement);

  // The selection: AND or OR, invert, clear
  const btn = (act: string) => bar.querySelector(`[data-act=${act}]`) as HTMLElement;
  const offCombine = store.subscribe(s => s.combine, c => btn('crossfilter').classList.toggle('active', c === 'and'),
    { fireImmediately: true });
  btn('crossfilter').addEventListener('click', () =>
    actions.setCombine(store.getState().combine === 'and' ? 'or' : 'and'));
  btn('invert').addEventListener('click', invertSelection);
  btn('clear').addEventListener('click', () => actions.clearSelection());
  const closeMeta = selectByMetadata(btn('meta'));
  const closeSave = saveForm(btn('save'));

  return { destroy() { off.abort(); offLayout(); offCombine(); closeMeta(); closeSave(); offJobs(); } };
}

// Save the viewer's work (adr/0026): a name and a description, beside the
// button. R saves it; a name taken asks again before replacing that save.
function saveForm(button: HTMLElement): () => void {
  const form = document.createElement('form');
  form.className = 'meta-sel-panel save-panel';
  form.innerHTML = `
    <div class="meta-sel-row">
      <input class="save-name" type="text" placeholder="name" autocomplete="off" spellcheck="false"
        pattern="[A-Za-z0-9_\\-]{1,64}" title="letters, digits, _ and -">
    </div>
    <div class="meta-sel-row">
      <input class="save-desc" type="text" placeholder="description (optional)" autocomplete="off">
      <button class="meta-sel-apply save-go" type="submit">save</button>
    </div>
    <div class="save-status"></div>`;
  button.ownerDocument.body.append(form);
  const $ = <T extends HTMLElement>(cls: string) => form.querySelector(cls) as T;
  const name = $<HTMLInputElement>('.save-name');
  const status = $<HTMLElement>('.save-status');
  const go = $<HTMLButtonElement>('.save-go');
  let replace = '';
  const reset = () => { replace = ''; go.textContent = 'save'; };
  name.addEventListener('input', reset);
  button.addEventListener('click', () => {
    const open = form.classList.toggle('visible');
    button.classList.toggle('active', open);
    if (!open) return;
    const r = button.getBoundingClientRect();
    Object.assign(form.style, { left: `${r.right + 6}px`, top: `${r.top}px` });
    status.textContent = '';
    status.classList.remove('error');
    reset();
    name.focus();
  });
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    const n = name.value.trim();
    if (!n) return;
    status.classList.remove('error');
    status.textContent = 'saving…';
    go.disabled = true;
    try {
      const res = await askR('save', { name: n, description: $<HTMLInputElement>('.save-desc').value,
        overwrite: replace === n });
      status.textContent = `saved ${res.save}`;
      reset();
    } catch (e: any) {
      if (e.code === 'exists') {
        replace = n;
        go.textContent = 'replace';
        status.textContent = `${e.message}: save again to replace it`;
      } else {
        status.textContent = e.message;
        status.classList.add('error');
      }
    } finally {
      go.disabled = false;
    }
  });
  return () => form.remove();
}

// Select by metadata: a form beside the button, over the page (the bar's
// panel scrolls and clips). Returns what removes it.
function selectByMetadata(button: HTMLElement): () => void {
  const form = document.createElement('div');
  form.className = 'meta-sel-panel';
  form.innerHTML = `
    <div class="meta-sel-row">
      <select class="meta-sel-col"></select>
      <select class="meta-sel-op">
        <option value="=">=</option><option value="!=">≠</option><option value=">">&gt;</option>
        <option value="<">&lt;</option><option value="LIKE">contains</option>
      </select>
    </div>
    <div class="meta-sel-row">
      <input class="meta-sel-val" type="text" placeholder="value…" autocomplete="off" spellcheck="false">
      <button class="meta-sel-apply">select</button>
    </div>`;
  button.ownerDocument.body.append(form);
  const $ = <T extends HTMLElement>(cls: string) => form.querySelector(cls) as T;
  button.addEventListener('click', () => {
    const open = form.classList.toggle('visible');
    button.classList.toggle('active', open);
    if (!open) return;
    const r = button.getBoundingClientRect();
    Object.assign(form.style, { left: `${r.right + 6}px`, top: `${r.top}px` });
    const names = state.metaInfo ? [...state.metaInfo.keys()] as string[] : [];
    $<HTMLSelectElement>('.meta-sel-col').innerHTML = names.length
      ? names.map(c => `<option value="${escapeHtml(c)}">${escapeHtml(c)}</option>`).join('')
      : '<option value="">no metadata loaded</option>';
  });
  $('.meta-sel-apply').addEventListener('click', () => {
    const col = $<HTMLSelectElement>('.meta-sel-col').value;
    const op  = $<HTMLSelectElement>('.meta-sel-op').value;
    const val = $<HTMLInputElement>('.meta-sel-val').value;
    if (!col || !state.metaInfo?.has(col)) return;
    filterMeta(col, (op === 'LIKE' ? 'contains' : op) as Parameters<typeof filterMeta>[1], val);
  });
  return () => form.remove();
}
