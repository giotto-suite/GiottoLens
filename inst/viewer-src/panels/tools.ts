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
import type { PanelHandle } from './dock.ts';
import { moduleList, setModule, moduleControls } from './modules.ts';
import { store } from '../core/store.ts';
import { state } from '../core/state.js';
import { railFlyout, type Flyout } from '../ui/flyout.ts';
import { createDataPanel } from './data.ts';

// The Data panel is a flyout from the rail, not a tray control: it fetches
// from the object, as opening a project or a save does, and its queue and
// pull outlast clicks elsewhere. Only with a giotto object shown (a catalog).
let dataFly: Flyout | null = null;
export function showData(): void { dataFly?.open(); }

export function initToolsRail(body: HTMLElement): PanelHandle {
  const off = new AbortController();
  const bar = document.createElement('div');
  bar.className = 'tools-bar';
  bar.innerHTML = `
    <button class="tool-btn" data-act="project" title="project: open a save, a snapshot or another project"><i data-lucide="folder-open"></i></button>
    <button class="tool-btn" data-act="info" title="about the object shown: its snapshot and what it holds (viewer$object_info())"><i data-lucide="info"></i></button>
    <button class="tool-btn" data-act="save" title="save the work in the viewer (viewer$save())"><i data-lucide="save"></i></button>
    <button class="tool-btn" data-act="data" title="data: pull what the object holds into the metadata (viewer$pull())"><i data-lucide="database"></i></button>
    <button class="tool-btn" data-act="modules" title="modules: a mode for one task (registration)"><i data-lucide="blocks"></i></button>
    <button class="tool-btn jobs-btn" data-act="jobs" title="jobs"><i data-lucide="activity"></i></button>
    <button class="tool-btn" data-act="preferences" title="preferences: defaults for every viewer"><i data-lucide="settings"></i></button>`;
  body.append(bar);
  createIcons({ icons, root: bar });

  initProjectButton(bar.querySelector('[data-act=project]') as HTMLElement, off.signal);
  initPreferencesButton(bar.querySelector('[data-act=preferences]') as HTMLElement, off.signal);
  const dataBtn = bar.querySelector('[data-act=data]') as HTMLElement;
  if (state.cells && state.manifest?.catalog) dataFly = railFlyout(dataBtn, 'data', 'data', createDataPanel);
  else dataBtn.style.display = 'none';
  const mods = bar.querySelector('[data-act=modules]') as HTMLElement;
  mods.addEventListener('click', () => openModulesMenu(mods));
  // Lit while a module is on
  const offModule = store.subscribe(s => s.module, () =>
    mods.classList.toggle('active', moduleList().some(m => m.on)), { fireImmediately: true });
  // Jobs R runs for the page, and cancelling them (ui/jobs.ts)
  const offJobs = jobsButton(bar.querySelector('[data-act=jobs]') as HTMLElement);
  const closeInfo = infoButton(bar.querySelector('[data-act=info]') as HTMLElement);
  const closeSave = saveForm(bar.querySelector('[data-act=save]') as HTMLElement);

  return { destroy() { off.abort(); closeSave(); offJobs(); closeInfo(); offModule(); dataFly?.destroy(); dataFly = null; } };
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

// The modules button's menu: modes for one task (panels/modules.ts), the one
// on ticked; picking it leaves it, picking another enters that one
function openModulesMenu(anchor: HTMLElement): void {
  const doc = anchor.ownerDocument;
  doc.querySelectorAll('.dock-menu.open').forEach(m => m.classList.remove('open'));
  const menu = Object.assign(doc.createElement('div'), { className: 'dock-menu open dock-menu-float modules-menu' });
  const r = anchor.getBoundingClientRect();
  Object.assign(menu.style, { left: `${r.right + 4}px`, top: `${r.top}px`, right: 'auto' });
  const close = () => { menu.remove(); doc.removeEventListener('click', close); };
  menu.append(...moduleList().map(m => {
    const item = Object.assign(doc.createElement('button'), {
      textContent: `${m.on ? '\u2713' : '\u2003'} ${m.label}`, disabled: !m.available,
      title: !m.available ? `${m.label} needs ${m.needs}` : m.on ? `leave ${m.label}` : `${m.label}: its controls and view alone` });
    item.dataset.module = m.id;
    item.dataset.controls = moduleControls(m.id).join(' ');
    item.addEventListener('click', () => { close(); setModule(m.on ? null : m.id); });
    return item;
  }));
  doc.body.append(menu);
  setTimeout(() => doc.addEventListener('click', close));   // not the click that opened it
}
