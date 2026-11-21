// The tools bar's info button: what the snapshot shown is and holds, in a
// popover beside it. R reads it from the files saved beside the snapshot
// (snapshot.json: who saved it and why; manifest.json: what the object holds)
// through the `object_info` ask, each time the popover opens, so an edit made
// in R since shows. viewer$object_info() returns the same.
// @ts-ignore: plain JS module
import { askR } from '../core/comms.js';
// @ts-ignore: plain JS module
import { escapeHtml } from './dom.js';

export interface InfoItem { name: string; detail?: string | null }
export interface InfoGroup { on: string; items: InfoItem[] }
export interface ObjectInfo {
  project: string;
  snapshot: {
    name: string; tag: string; created?: string | null; creator?: string | null;
    owner?: string | null; keep?: boolean | null; description?: string | null;
    labels: string[]; parents: string[]; object?: string | null;
    extra: Record<string, string> | [];
  };
  save?: { name: string; updated?: string | null; description?: string | null; labels: string[] } | null;
  object?: { class: string; uid: string; written_by?: string; history_steps?: number } | null;
  counts?: { cells: Record<string, number>; features: Record<string, number> } | null;
  contents?: Record<string, InfoGroup[]> | null;
}

// The manifest's slots in reading order, with their names on the page; a
// slot not listed here follows under its own name
const SLOTS: [string, string][] = [
  ['expression', 'expression'],
  ['spatial_info', 'polygons'],
  ['spatial_locs', 'spatial locations'],
  ['feat_info', 'points'],
  ['cell_metadata', 'cell metadata'],
  ['feat_metadata', 'feature metadata'],
  ['dimension_reduction', 'dim reductions'],
  ['nn_network', 'nearest-neighbour networks'],
  ['spatial_network', 'spatial networks'],
  ['spatial_enrichment', 'spatial enrichments'],
  ['images', 'images'],
];

const when = (iso?: string | null) => iso ? new Date(iso).toLocaleString() : '';
const nf = (n: number) => n.toLocaleString();

// The popover's HTML for `info`; exported for the tests
export function renderInfo(info: ObjectInfo): string {
  const s = info.snapshot;
  const row = (k: string, v?: string | null, cls = '') =>
    v ? `<div class="info-row"><span class="info-key">${escapeHtml(k)}</span><span class="info-val ${cls}">${escapeHtml(v)}</span></div>` : '';
  const tags = (xs: string[]) => xs.map(x => `<span class="info-tag">${escapeHtml(x)}</span>`).join('');
  const extra = Array.isArray(s.extra) ? [] : Object.entries(s.extra);

  let html = `<div class="info-title" title="${escapeHtml(s.tag)}">${escapeHtml(s.name)}` +
    (s.keep === false ? `<span class="info-tag info-temp" title="not kept: removed when the session ends unless kept">temporary</span>` : '') +
    `</div>` +
    (s.description ? `<div class="info-desc">${escapeHtml(s.description)}</div>` : '') +
    (s.labels.length ? `<div class="info-tags">${tags(s.labels)}</div>` : '') +
    row('owner', s.owner) + row('saved by', s.creator) + row('created', when(s.created)) +
    row('from', s.parents.join(', ')) +
    extra.map(([k, v]) => row(k, v)).join('') +
    row('project', info.project, 'info-path');

  if (info.save) {
    const v = info.save;
    html += `<div class="info-head">Lens save</div>` + row('name', v.name) +
      (v.description ? `<div class="info-desc">${escapeHtml(v.description)}</div>` : '') +
      (v.labels.length ? `<div class="info-tags">${tags(v.labels)}</div>` : '') +
      row('updated', when(v.updated));
  }

  if (!info.contents) {
    return html + `<div class="info-none">This snapshot has no manifest.json, so what it holds is not listed. Save it again to write one.</div>`;
  }
  const o = info.object;
  if (o) html += `<div class="info-head">object</div>` + row('class', o.class) + row('uid', o.uid) +
    row('written by', o.written_by) + row('history', o.history_steps != null ? `${o.history_steps} steps` : '');
  const counts = (title: string, c?: Record<string, number>) => c && Object.keys(c).length
    ? `<div class="info-head">${title}</div>` + Object.entries(c).map(([k, n]) => row(k, nf(n), 'info-num')).join('')
    : '';
  html += counts('cells', info.counts?.cells) + counts('features', info.counts?.features);

  const c = info.contents;
  const order = [...SLOTS.filter(([k]) => k in c), ...Object.keys(c).filter(k => !SLOTS.some(([s]) => s === k)).map(k => [k, k.replace(/_/g, ' ')] as [string, string])];
  for (const [slot, title] of order) {
    const groups = c[slot];
    const n = groups.reduce((a, g) => a + g.items.length, 0);
    html += `<details class="info-slot"><summary><span>${escapeHtml(title)}</span><span class="info-count">${n}</span></summary>` +
      groups.map(g => `<div class="info-group">` +
        (g.on ? `<div class="info-on">${escapeHtml(g.on)}</div>` : '') +
        `<div class="info-items">` + g.items.map(i =>
          `<span class="info-item"${i.detail ? ` title="${escapeHtml(i.detail)}"` : ''}>${escapeHtml(i.name)}` +
          (i.detail ? `<span class="info-detail">${escapeHtml(i.detail)}</span>` : '') + `</span>`).join('') +
        `</div></div>`).join('') +
      `</details>`;
  }
  return html;
}

// The button's popover. Returns what removes it.
export function infoButton(button: HTMLElement): () => void {
  const pop = Object.assign(document.createElement('div'), { className: 'jobs-popover info-popover' });
  let seq = 0;

  const place = () => {
    const r = button.getBoundingClientRect();
    Object.assign(pop.style, { left: `${r.right + 6}px`, top: `${Math.max(4, Math.min(r.top, innerHeight - pop.offsetHeight - 4))}px` });
  };
  const close = () => {
    seq++;
    pop.remove();
    button.classList.remove('active');
    document.removeEventListener('pointerdown', outside, true);
    document.removeEventListener('keydown', keys);
  };
  const outside = (e: PointerEvent) => {
    const t = e.target as Node;
    if (!pop.contains(t) && !button.contains(t)) close();
  };
  const keys = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
  // A section opened or closed changes the height
  pop.addEventListener('toggle', place, true);

  button.addEventListener('click', async () => {
    if (pop.isConnected) { close(); return; }
    document.body.append(pop);
    button.classList.add('active');
    pop.innerHTML = `<div class="jobs-none">reading…</div>`;
    place();
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('keydown', keys);
    const mine = ++seq;
    try {
      const info: ObjectInfo = await askR('object_info');
      if (mine !== seq) return;
      pop.innerHTML = renderInfo(info);
    } catch (e: any) {
      if (mine !== seq) return;
      pop.innerHTML = `<div class="jobs-none">${escapeHtml(e.message)}</div>`;
    }
    place();
  });

  return close;
}
