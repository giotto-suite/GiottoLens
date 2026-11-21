// The selection panel, a control in the tray (adr/0027). From the top: how
// the sources' rules combine (AND, the cross-filter, or OR), invert and
// clear; the rules behind the selection, a card per source with what it
// selects and how many cells it matches on its own, × to drop one; and the
// saved selections (panels/saved.ts). The count is the selection bar's
// (ui/selbar.js); the metadata filter is the table's (panels/filter.ts).
import { store, actions } from '../core/store.ts';
import { invertSelection, ctx } from '../selection/selection.ts';
import { evaluate, countMask } from '../selection/rules.ts';
// @ts-ignore: plain JS module
import { ruleLabel } from '../ui/rules.js';
import { createSavedSection } from './saved.ts';
import type { PanelHandle } from './dock.ts';

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

export function createSelectionPanel(body: HTMLElement): PanelHandle {
  const root = el('div', { className: 'selection-panel' });
  body.append(root);
  const button = (act: string, text: string, title: string) => {
    const b = el('button', { textContent: text, title });
    b.dataset.act = act;
    return b;
  };
  const row = (...kids: HTMLElement[]) => {
    const r = el('div', { className: 'ctl-actions' });
    r.append(...kids);
    return r;
  };

  // AND or OR, invert, clear
  const and = button('and', 'and', 'cross-filter: the cells every source selects');
  const or  = button('or', 'or', 'union: the cells any source selects');
  and.addEventListener('click', () => actions.setCombine('and'));
  or.addEventListener('click', () => actions.setCombine('or'));
  const invert = button('invert', 'invert', 'invert the selection');
  const clear  = button('clear', 'clear', 'clear the selection (C)');
  invert.addEventListener('click', invertSelection);
  clear.addEventListener('click', () => actions.clearSelection());
  const top = el('div', { className: 'sel-top' });
  top.append(el('div', { className: 'ctl-subhead', textContent: 'combine' }), row(and, or), row(invert, clear));

  // The rules, one card per source
  const cards = el('div', { className: 'sel-rules' });
  const renderRules = () => {
    const s = store.getState();
    const entries = Object.entries(s.rules);
    const c = ctx();
    cards.replaceChildren(...entries.map(([source, rule]) => {
      const card = el('div', { className: 'rule-card' });
      card.dataset.source = source;
      let n = '';
      try { if (c) n = countMask(evaluate(rule, c)).toLocaleString(); } catch (_) { n = '?'; }
      const label = el('span', { className: 'rule-label', textContent: ruleLabel(rule),
        title: JSON.stringify(rule.params).slice(0, 300) });
      const x = el('button', { className: 'rule-x', textContent: '×', title: `drop the ${source} rule` });
      x.addEventListener('click', () => actions.setRule(source, null));
      const meta = el('div', { className: 'rule-meta' });
      meta.append(el('span', { className: 'rule-source', textContent: source }),
        el('span', { className: 'rule-n', textContent: n && `${n} cells` }));
      const head = el('div', { className: 'rule-head' });
      head.append(label, x);
      card.append(head, meta);
      return card;
    }));
    if (!entries.length)
      cards.append(el('div', { className: 'rule-empty', textContent: 'no rules: select cells in a view or a chart' }));
  };

  const saved = createSavedSection();
  root.append(top,
    el('div', { className: 'ctl-subhead sel-head', textContent: 'rules' }), cards,
    el('div', { className: 'ctl-subhead sel-head', textContent: 'saved selections' }), saved.el);

  const offCombine = store.subscribe(s => s.combine, c => {
    and.classList.toggle('active', c === 'and');
    or.classList.toggle('active', c === 'or');
  }, { fireImmediately: true });
  // Counts change as the rules' columns load, which bumps the selection
  const offRules = store.subscribe(s => s.selection.version, renderRules);
  const offRuleSet = store.subscribe(s => s.rules, renderRules);
  renderRules();

  return { destroy() { offCombine(); offRules(); offRuleSet(); saved.destroy(); } };
}
