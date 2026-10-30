// Shared pieces of the stats panels: control bar, chart area, title
import { createIcons, icons } from 'lucide';

// fields: [{ key, label, options: [value | { value, label }], value }]
// buttons: [{ icon, title, onClick, toggle?: group name, active? }]
export function buildControlBar(body, fields, buttons = []) {
  body.querySelector('.stats-controls')?.remove();
  const bar = document.createElement('div');
  bar.className = 'stats-controls';
  const els = {};
  for (const { key, label, options, value } of fields) {
    const wrap = document.createElement('label');
    wrap.className = 'stats-ctrl-wrap';
    wrap.textContent = label;
    const sel = document.createElement('select');
    sel.className = 'stats-ctrl-sel';
    for (const o of options) {
      const opt = document.createElement('option');
      opt.value = o.value ?? o;
      opt.textContent = o.label ?? o;
      sel.appendChild(opt);
    }
    if (value != null) sel.value = value;
    wrap.appendChild(sel);
    bar.appendChild(wrap);
    els[key] = sel;
  }
  if (buttons.length) {
    const sep = document.createElement('span');
    sep.className = 'stats-ctrl-sep';
    bar.appendChild(sep);
  }
  for (const b of buttons) {
    const btn = document.createElement('button');
    btn.className = 'tool-btn' + (b.active ? ' active' : '');
    btn.title = b.title;
    if (b.toggle) btn.dataset.toggle = b.toggle;
    const i = document.createElement('i');
    i.setAttribute('data-lucide', b.icon);
    btn.appendChild(i);
    btn.addEventListener('click', () => {
      if (b.toggle) bar.querySelectorAll(`[data-toggle="${b.toggle}"]`).forEach(x => x.classList.toggle('active', x === btn));
      b.onClick(btn);
    });
    bar.appendChild(btn);
    els[`btn:${b.title}`] = btn;
  }
  body.insertBefore(bar, body.firstChild);
  createIcons({ icons, nodes: bar.querySelectorAll('[data-lucide]') });
  return els;
}

export function chartArea(body) {
  let a = body.querySelector('.stats-chart-area');
  if (!a) { a = document.createElement('div'); a.className = 'stats-chart-area'; body.appendChild(a); }
  return a;
}

export function setTitle(body, title) {
  const h = body.closest('.stats-pane')?.querySelector('.stats-pane-title');
  if (h) h.textContent = title;
}
