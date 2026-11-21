// A rule's short label: the selection panel's rule cards (panels/selection.ts)
// and the table filter's summary (panels/filter.ts).

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
    case 'ids':        s = rule.source === 'r' ? 'from R' : rule.source?.startsWith('panel') ? 'panel brush'
      : rule.source?.startsWith('table') ? 'table rows' : 'cell list'; break;
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
