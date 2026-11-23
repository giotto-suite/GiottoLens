// The selection bar along the bottom of the page (adr/0023). The selection is
// one for the whole page, rules from every view and panel combined with OR or
// AND, so its count lives here rather than in a view, with how many rules make
// it and how they combine (the mode's symbol: intersect for AND, unite for OR);
// the rules open the selection panel, which lists them
// (panels/selection.ts). R's connection and the stop button (viewer$close())
// are at its left end, the status line and the panels toggle at its right.
import { createIcons, icons } from 'lucide';
import { store, actions } from '../core/store.ts';
import { liveView, onLive } from '../selection/live.ts';
import { onRStatus, sendToR } from '../core/comms.js';
import { showControl } from '../panels/tray.ts';
import { togglePanels, panelsShown, onLayoutChange } from '../panels/dock.ts';

const CLOSE_ARM_MS = 3000;

// R's connection and the stop button; also on the start page
export function initRStatus() {
  const dot = document.getElementById('r-status');
  const stop = document.getElementById('btn-close');
  const status = document.getElementById('status');
  // Two clicks, since a native confirm() can be blocked in an IDE's viewer pane
  let armed;
  function disarm() {
    clearTimeout(armed);
    armed = undefined;
    stop.classList.remove('armed');
    stop.title = 'stop the viewer (viewer$close())';
  }
  onRStatus(s => {
    dot.className = `r-status ${s}`;
    dot.title = `R: ${s}`;
    // Only while connected: a message sent while disconnected is queued, and
    // would stop the viewer on reconnect
    stop.disabled = s !== 'connected';
    if (s !== 'connected') disarm();
    if (s === 'closed') status.textContent = 'viewer stopped; launch_lens() starts a new one';
  });

  stop.addEventListener('click', () => {
    if (armed === undefined) {
      stop.classList.add('armed');
      stop.title = 'click again to stop the viewer';
      status.textContent = 'click the power button again to stop the viewer';
      armed = setTimeout(() => { disarm(); status.textContent = ''; }, CLOSE_ARM_MS);
      return;
    }
    disarm();
    status.textContent = 'stopping…';
    sendToR('close');
  });
}

export function initSelectionBar() {
  initRStatus();

  // A panel brush being dragged shows its live count (adr/0013)
  const count = document.getElementById('sel-count');
  const update = () => {
    const n = liveView()?.count ?? store.getState().selection.count;
    count.textContent = n > 0 ? `${n.toLocaleString()} selected` : 'none selected';
    count.classList.toggle('none', !(n > 0));
  };
  store.subscribe(s => s.selection, update);
  onLive(update);
  update();

  // The rules, before the count so the count's width moves nothing: amber
  // when they leave no cell, as AND over sources that do not overlap does
  const rules = document.getElementById('sel-rules');
  const updateRules = () => {
    const s = store.getState();
    const n = Object.keys(s.rules).length;
    rules.style.display = n ? '' : 'none';
    rules.textContent = n > 1 ? `${n} rules` : '1 rule';
    const empty = n > 0 && s.selection.count === 0 && !liveView();
    rules.classList.toggle('empty', empty);
    rules.title = empty
      ? (n > 1 && s.combine === 'and' ? 'no cell meets every rule: ' : 'the rules select no cell: ') +
        'show them in the selection panel'
      : 'show the rules in the selection panel';
  };
  rules.addEventListener('click', () => showControl('selection'));

  // The combine mode, always shown: it decides what the next rule does
  const mode = document.getElementById('sel-mode');
  const updateMode = () => {
    const and = store.getState().combine === 'and';
    mode.innerHTML = `<i data-lucide="${and ? 'squares-intersect' : 'squares-unite'}"></i>`;
    mode.title = and ? 'and: the cells every rule selects (cross-filter)' : 'or: the cells any rule selects';
    mode.dataset.mode = and ? 'and' : 'or';
    createIcons({ icons, root: mode });
  };
  store.subscribe(s => s.combine, updateMode);
  updateMode();
  store.subscribe(s => s.rules, updateRules);
  store.subscribe(s => s.combine, updateRules);
  store.subscribe(s => s.selection, updateRules);
  updateRules();

  // Escape returns the panels' tools to pan; C clears the selection
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') document.dispatchEvent(new CustomEvent('lens:pan'));
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName)) return;
    if (e.key === 'c') actions.clearSelection();
  });
}

// The panels toggle, at the bar's right end: the spatial view alone and the
// tray hidden, or everything back (panels/dock.ts togglePanels()). Lit while
// the panels show. After the dock, whose layout it follows.
export function initPanelsToggle() {
  const btn = document.getElementById('btn-panels');
  const showState = () => btn.classList.toggle('active', panelsShown());
  btn.addEventListener('click', () => { togglePanels(); showState(); });
  onLayoutChange(showState);
  showState();
}
