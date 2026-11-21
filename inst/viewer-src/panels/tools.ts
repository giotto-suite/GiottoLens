// The tools rail (adr/0023, adr/0027): the page's own controls, a column of
// icons fixed at the page's left edge, outside the dock, as the tray's rail is
// at the right. The actions on the selection are the selection panel's, in
// the tray (panels/selection.ts); the tools that act in one view stay in that
// view.
import { createIcons, icons } from 'lucide';
import { initProjectButton } from '../ui/start.ts';
import { jobsButton } from '../ui/jobs.ts';
import { infoButton } from '../ui/info.ts';
import { initPreferencesButton } from '../ui/preferences.ts';
import { askR } from '../core/comms.js';
import { togglePanels, panelsShown, onLayoutChange, openAddMenu, type PanelHandle } from './dock.ts';

export function initToolsRail(body: HTMLElement): PanelHandle {
  const off = new AbortController();
  const bar = document.createElement('div');
  bar.className = 'tools-bar';
  bar.innerHTML = `
    <button class="tool-btn" data-act="project" title="project: open a save, a snapshot or another project"><i data-lucide="folder-open"></i></button>
    <button class="tool-btn" data-act="info" title="about the object shown: its snapshot and what it holds (viewer$object_info())"><i data-lucide="info"></i></button>
    <button class="tool-btn" data-act="save" title="save the work in the viewer (viewer$save())"><i data-lucide="save"></i></button>
    <button class="tool-btn" data-act="panels" title="show or hide the panels beside the spatial view"><i data-lucide="bar-chart-2"></i></button>
    <button class="tool-btn" data-act="add" title="add a panel"><i data-lucide="plus"></i></button>
    <button class="tool-btn jobs-btn" data-act="jobs" title="jobs"><i data-lucide="activity"></i></button>
    <button class="tool-btn" data-act="preferences" title="preferences: defaults for every viewer"><i data-lucide="settings"></i></button>`;
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
  const closeInfo = infoButton(bar.querySelector('[data-act=info]') as HTMLElement);
  const closeSave = saveForm(bar.querySelector('[data-act=save]') as HTMLElement);

  return { destroy() { off.abort(); offLayout(); closeSave(); offJobs(); closeInfo(); } };
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
