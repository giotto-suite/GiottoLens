// Saved selections, the selection panel's lower section (adr/0029): the
// selection's rules and how they combine, saved under a name. A click brings
// those rules back under their own sources, editable as before. R holds them
// and sends them as `selections`, with the cells each selects now; the
// section acts through the `selection` ask. viewer$save_selection(),
// restore_selection(), remove_selection() are the same from R, and
// compare_selections() tests two of them (a job; its results dock as a
// volcano plot).
import { createIcons, icons } from 'lucide';
import { store } from '../core/store.ts';
// @ts-ignore: plain JS module
import { askR, onMessage } from '../core/comms.js';
// @ts-ignore: plain JS module
import { ruleLabel } from '../ui/rules.js';
import { readSaved, nextName, type Saved, type SavedMsg } from './saved-model.ts';

let saved: Saved[] = [];
const mounted = new Set<() => void>();

// Before initComms(), like every handler. `show` brings the section forward,
// when one is saved (`open`)
export function initSaved(show: () => void) {
  onMessage('selections', (msg: SavedMsg) => {
    saved = readSaved(msg);
    if (msg.open) show();
    mounted.forEach(fn => fn());
  });
}

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, className = '', text = ''): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), { className, textContent: text });

export function createSavedSection(): { el: HTMLElement; destroy(): void } {
  const root = el('div', 'rg');
  const name = el('input', 'rg-name');
  Object.assign(name, { type: 'text', spellcheck: false, autocomplete: 'off' });
  const save = el('button', 'rg-btn rg-save', 'save');
  save.title = "save the selection's rules under this name";
  const list = el('div', 'rg-list');
  const status = el('div', 'rg-status');
  const saveRow = el('div', 'rg-row');
  saveRow.append(name, save);
  root.append(saveRow, list, status);

  // Only errors are shown, until the next action
  const act = (args: object) => {
    status.textContent = '';
    return askR('selection', args).catch((e: Error) => {
      status.textContent = String(e.message ?? e);
      status.className = 'rg-status rg-error';
    });
  };

  function doSave() {
    const n = name.value.trim() || nextName(saved);
    name.value = '';
    void act({ action: 'save', name: n });
  }
  save.addEventListener('click', doSave);
  name.addEventListener('keydown', e => { if (e.key === 'Enter' && !save.disabled) doSave(); });

  function render() {
    name.placeholder = nextName(saved);
    save.disabled = !Object.keys(store.getState().rules).length;
    // Rows as the annotations panel's: a click brings the rules back, ×
    // removes it
    list.replaceChildren(...saved.map(s => {
      const row = el('div', 'annot-row rg-item');
      row.dataset.saved = s.name;
      const labels = s.rules.map(r => ruleLabel(r));
      row.title = `bring back these rules (${s.combine}):\n${labels.join('\n')}`;
      const del = el('button', 'annot-row-btn rg-del');
      del.title = 'remove it';
      del.innerHTML = '<i data-lucide="x"></i>';
      del.addEventListener('click', e => { e.stopPropagation(); void act({ action: 'remove', name: s.name }); });
      row.addEventListener('click', () => void act({ action: 'restore', name: s.name }));
      const rules = s.rules.length === 1 ? '1 rule' : `${s.rules.length} rules`;
      row.append(el('span', 'annot-name-text', s.name), el('span', 'rg-n', `${rules} · ${s.n.toLocaleString()}`), del);
      return row;
    }));
    createIcons({ icons, root: list });
    if (!saved.length) list.append(el('div', 'rg-empty', 'none saved yet'));
  }

  mounted.add(render);
  const unsub = store.subscribe(s => s.rules, render);
  render();
  return { el: root, destroy() { mounted.delete(render); unsub(); } };
}

// For tests and the browser console
export const savedList = () => saved;
