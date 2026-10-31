// The rules behind the selection, as chips under the HUD: what each source
// selects and how many cells it matches on its own, with × to drop one.
// Hidden with the toolbar's rules button when it gets in the way.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { evaluate, countMask } from '../selection/rules.ts';
import { ctx } from '../selection/selection.ts';

const fmt = x => Number.isInteger(x) ? x.toLocaleString() : Number(x.toPrecision(3)).toLocaleString();

// Short label for a rule
export function ruleLabel(rule) {
  const p = rule.params ?? {};
  let s;
  switch (rule.kind) {
    case 'polygon':
      s = rule.space === 'spatial' ? 'lasso' : `lasso in ${rule.space?.x} × ${rule.space?.y}`;
      if (p.rings?.length > 1) s += ` ×${p.rings.length}`;
      break;
    case 'stroke':     s = 'brush'; break;
    case 'range':      s = `${rule.space} ${fmt(p.min)}–${fmt(p.max)}`; break;
    case 'categories': s = `${rule.space}: ${p.values.slice(0, 3).join(', ')}${p.values.length > 3 ? ` +${p.values.length - 3}` : ''}`; break;
    case 'compare':    s = `${rule.space} ${p.op} ${p.value}`; break;
    // Parts of a union or intersection sent from R have no source
    case 'ids':        s = rule.source === 'r' ? 'from R' : rule.source?.startsWith('panel') ? 'panel brush' : 'cell list'; break;
    case 'union': {
      const kinds = [...new Set(p.parts.map(r => ruleLabel(r)))];
      s = kinds.length === 1 && p.parts.length > 1 ? `${kinds[0]} ×${p.parts.length}` : kinds.join(' + ');
      break;
    }
    case 'intersect':   // subtracted strokes are negated parts: "lasso − brush"
      s = p.parts.map((r, i) => i && r.negate ? `− ${ruleLabel({ ...r, negate: false })}` : (i ? `∩ ${ruleLabel(r)}` : ruleLabel(r))).join(' ');
      break;
    default: s = rule.kind;
  }
  return rule.negate ? `not ${s}` : s;
}

function render(el) {
  const s = store.getState();
  const entries = Object.entries(s.rules);
  el.replaceChildren();
  el.style.display = s.showRules && entries.length ? '' : 'none';
  if (!s.showRules || !entries.length) return;
  const c = ctx();
  for (const [source, rule] of entries) {
    const chip = document.createElement('span');
    chip.className = 'rule-chip';
    chip.dataset.source = source;
    let n = '';
    try { if (c) n = ` · ${countMask(evaluate(rule, c)).toLocaleString()}`; } catch (_) { n = ' · ?'; }
    const label = document.createElement('span');
    label.textContent = ruleLabel(rule) + n;
    label.title = `${source}: ${JSON.stringify(rule.params).slice(0, 300)}`;
    const x = document.createElement('button');
    x.className = 'rule-chip-x';
    x.textContent = '×';
    x.title = `drop the ${source} rule`;
    x.addEventListener('click', e => { e.stopPropagation(); actions.setRule(source, null); });
    chip.append(label, x);
    el.appendChild(chip);
  }
  if (entries.length > 1) {
    const mode = document.createElement('span');
    mode.className = 'rule-chip rule-mode';
    mode.textContent = s.combine === 'and' ? 'AND' : 'OR';
    mode.title = s.combine === 'and' ? 'cells matching every rule (cross-filter)' : 'cells matching any rule';
    el.appendChild(mode);
  }
}

export function initRuleStrip() {
  const el = document.getElementById('rule-strip');
  const btn = document.getElementById('btn-rules');
  if (!el) return;
  const update = () => render(el);
  store.subscribe(s => s.selection.version, update);
  store.subscribe(s => s.showRules, on => { btn?.classList.toggle('active', on); update(); }, { fireImmediately: true });
  store.subscribe(s => s.combine, update);
  btn?.addEventListener('click', () => actions.setShowRules(!store.getState().showRules));
  update();
}
