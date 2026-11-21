// Shared pieces of the stats panels: control bar, tool stack, chart area,
// hidden-panel updates
import { createIcons, icons } from 'lucide';

// fields: [{ key, label, options: [value | { value, label }], value }]
// buttons: [{ icon, title, onClick, toggle?: group name, active? }]
// The fields go in the bar along the top. The buttons are view tools and go in
// a vertical stack over the chart's lower right (`els.tools`), so a narrow pane's
// bar does not wrap onto a second row. The stack is the body's, not the chart
// area's: panels replace the area's children.
export function buildControlBar(body, fields, buttons = []) {
  body.querySelector('.stats-controls')?.remove();
  body.querySelector('.chart-tools')?.remove();
  const bar = document.createElement('div');
  bar.className = 'stats-controls';
  /** @type {Record<string, HTMLElement>} */
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
  const tools = document.createElement('div');
  tools.className = 'chart-tools';
  for (const b of buttons) {
    const btn = document.createElement('button');
    btn.className = 'tool-btn' + (b.active ? ' active' : '');
    btn.title = b.title;
    if (b.toggle) btn.dataset.toggle = b.toggle;
    const i = document.createElement('i');
    i.setAttribute('data-lucide', b.icon);
    btn.appendChild(i);
    btn.addEventListener('click', () => {
      if (b.toggle) tools.querySelectorAll(`[data-toggle="${b.toggle}"]`).forEach(x => x.classList.toggle('active', x === btn));
      b.onClick(btn);
    });
    tools.appendChild(btn);
    els[`btn:${b.title}`] = btn;
  }
  body.insertBefore(bar, body.firstChild);
  if (buttons.length) {
    body.appendChild(tools);
    els.tools = tools;
    createIcons({ icons, nodes: tools.querySelectorAll('[data-lucide]') });
  }
  return els;
}

export function chartArea(body) {
  let a = body.querySelector('.stats-chart-area');
  if (!a) { a = document.createElement('div'); a.className = 'stats-chart-area'; body.appendChild(a); }
  return a;
}

// Runs `fn` now if the panel is in view, otherwise once it comes into view
// (a background tab): `update()` where the panel would redraw, and the
// returned `show` as the panel's PanelHandle.show (panels/dock.ts).
export function whenVisible(ctx, fn) {
  let stale = false;
  return {
    update() { if (ctx.visible()) { stale = false; fn(); } else stale = true; },
    show() { if (stale) { stale = false; fn(); } },
  };
}
