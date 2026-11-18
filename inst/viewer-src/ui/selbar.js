// The selection bar along the bottom of the page (adr/0023). The selection is
// one for the whole page, rules from every view and panel combined with OR or
// AND, so its count and its rules (ui/rules.js) live here rather than in a
// view; the actions on it are the tools bar's (panels/tools.ts). R's
// connection is at its left end and the status line at its right.
import { store, actions } from '../core/store.ts';
import { liveView, onLive } from '../selection/live.ts';
import { onRStatus } from '../core/comms.js';

export function initSelectionBar() {
  const dot = document.getElementById('r-status');
  onRStatus(s => { dot.className = `r-status ${s}`; dot.title = `R: ${s}`; });

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

  // Escape returns the panels' tools to pan; C clears the selection
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') document.dispatchEvent(new CustomEvent('lens:pan'));
    if (['INPUT', 'TEXTAREA', 'SELECT'].includes(document.activeElement?.tagName)) return;
    if (e.key === 'c') actions.clearSelection();
  });
}
