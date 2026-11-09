// State of the Analysis panel (launch_lens_analysis()): the step tree and
// parameter menus R sent, the status of each step, and the marker table with
// the cluster labels. R owns all of it; the panel shows it and sends changes.

export interface Choice { value: string; label: string }
export interface Slider { min: number; max: number; step?: number | null; log?: boolean }
export interface Param {
  id: string; label: string; value: string; choices: Choice[];
  type?: 'choice' | 'number' | 'range'; min?: number | null; max?: number | null;
  integer?: boolean; auto?: boolean; slider?: Slider | null;
}
export interface Step { id: string; label: string; fun: string; input: string | null; params: Param[] }
export interface SavedSettings { name: string; time: string }
export interface Schema {
  disk: boolean; steps: Step[]; cell_markers?: number; settings?: SavedSettings[]; region?: number;
}
export type StatusName = 'stale' | 'running' | 'done' | 'error' | 'blocked';
export interface StepStatus { status: StatusName; secs?: number; summary?: string; message?: string }
export interface Marker { cluster: string; feat: string; score: number }
export interface Inherited { from: string; share: number }
export interface Suggestion { cluster: string; type: string; share: number; n?: number }
export interface ClusterRow {
  cluster: string; feats: string[]; label: string; inherited?: Inherited;
  suggested?: boolean; suggestion?: Suggestion;
}

export interface AnalysisModel {
  schema: Schema | null;
  status: Record<string, StepStatus>;
  markers: Marker[];
  labels: Record<string, string>;
  inherited: Record<string, Inherited>;
  suggested: Record<string, { type: string; share: number }>;
  suggestions: Suggestion[];
}

export const emptyModel = (): AnalysisModel => ({
  schema: null, status: {}, markers: [], labels: {}, inherited: {}, suggested: {}, suggestions: [],
});

// The step and every step below it
export function descendants(steps: Step[], id: string): string[] {
  const out = [id];
  for (let added = true; added;) {
    added = false;
    for (const s of steps)
      if (s.input && out.includes(s.input) && !out.includes(s.id)) { out.push(s.id); added = true; }
  }
  return out;
}

// A menu change before R answers: the value is set and the step and those below
// it show as stale. Returns false for an unknown step, parameter or value.
export function applyParam(m: AnalysisModel, step: string, param: string, value: string): boolean {
  const st = m.schema?.steps.find(s => s.id === step);
  const p = st?.params.find(q => q.id === param);
  if (!st || !p) return false;
  if (p.type === 'number' || p.type === 'range') {
    const key = p.type === 'range' ? rangeKey(p, value) : numberKey(p, value);
    if (key == null) return false;
    value = key;
  } else if (!p.choices.some(c => c.value === value)) return false;
  if (p.value === value) return false;
  p.value = value;
  for (const d of descendants(m.schema!.steps, step)) m.status[d] = { status: 'stale' };
  return true;
}

// A typed number as the key R takes ('auto' for an empty box where allowed),
// or null when it is not a valid value for the parameter
export function numberKey(p: Param, raw: string): string | null {
  const t = raw.trim();
  if (t === '' || t === 'auto') return p.auto ? 'auto' : null;
  if (!/^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/.test(t)) return null;
  const x = Number(t);
  if (!Number.isFinite(x)) return null;
  if (p.integer && !Number.isInteger(x)) return null;
  if (p.min != null && x < p.min) return null;
  if (p.max != null && x > p.max) return null;
  return String(x);
}

// PCs as 'from:to' (whole numbers, from < to, to within the last PC), or null
export function rangeKey(p: Param, raw: string): string | null {
  const m = /^\s*(\d+)\s*:\s*(\d+)\s*$/.exec(raw);
  if (!m) return null;
  const from = Number(m[1]), to = Number(m[2]);
  if (from < (p.min ?? 1) || to <= from) return null;
  if (p.max != null && to > p.max) return null;
  return `${from}:${to}`;
}

// Slider position <-> value; log sliders run over log10 of the value
export function sliderPos(s: Slider, x: number): number {
  return s.log ? Math.log10(Math.max(x, Number.MIN_VALUE)) : x;
}
export function sliderValue(s: Slider, pos: number, integer = false): number {
  let x = s.log ? Number((10 ** pos).toPrecision(3)) : pos;
  if (!s.log && s.step) x = Number((Math.round(x / s.step) * s.step).toFixed(6));
  return integer ? Math.round(x) : x;
}

// The range a number box accepts, for its tooltip
export function rangeText(p: Param): string {
  const kind = p.integer ? 'whole number' : 'number';
  const lo = p.min != null ? `≥ ${p.min}` : '';
  const hi = p.max != null ? `≤ ${p.max}` : '';
  return [kind, lo, hi].filter(Boolean).join(' ') + (p.auto ? '; empty for auto' : '');
}

// Clusters in numeric order with their markers in R's order
export function clusterRows(m: AnalysisModel): ClusterRow[] {
  const by = new Map<string, string[]>();
  for (const r of m.markers) {
    const k = String(r.cluster);
    if (!by.has(k)) by.set(k, []);
    by.get(k)!.push(r.feat);
  }
  const keys = [...by.keys()].sort((a, b) => {
    const na = Number(a), nb = Number(b);
    return Number.isFinite(na) && Number.isFinite(nb) ? na - nb : a.localeCompare(b);
  });
  const sug = new Map(m.suggestions.map(x => [String(x.cluster), x]));
  return keys.map(k => ({ cluster: k, feats: by.get(k)!, label: m.labels[k] ?? '',
    ...(m.inherited[k] && { inherited: m.inherited[k] }),
    ...(m.suggested[k] && { suggested: true }),
    ...(sug.has(k) && { suggestion: sug.get(k) }) }));
}

// Labels as R takes them: clusters with a non-empty label only
export function labelPayload(labels: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(labels)) if (v.trim()) out[k] = v.trim();
  return out;
}

export function statusText(s: StepStatus | undefined): string {
  if (!s) return 'stale';
  if (s.status === 'done') return s.secs != null ? `done ${s.secs.toFixed(1)} s` : 'done';
  return s.status;
}

// One line for the panel header: what is running or waiting
export function overall(m: AnalysisModel): string {
  const st = Object.values(m.status);
  if (!m.schema) return 'waiting for R…';
  if (st.some(s => s.status === 'running')) return 'running…';
  if (st.some(s => s.status === 'error')) return 'error';
  if (st.some(s => s.status === 'stale')) return 'queued';
  return 'up to date';
}

// Cluster colors that follow the labels: each labeled cluster takes the color
// its label has in the cell type column (its style, else its palette color).
// `auto` holds the colors set this way before; a cluster whose color differs
// from that was colored by hand and is left alone. Returns the style patch
// for the cluster column and the new `auto`.
export type RGB = [number, number, number];
export function clusterColorPatch(
  labels: Record<string, string>,
  clusterLevels: string[],
  typeLevels: string[],
  typeStyles: Record<string, { color?: number[] }>,
  clusterStyles: Record<string, { color?: number[] }>,
  palette: number[][],
  auto: Record<string, RGB>,
): { patch: Record<string, { color?: RGB }>; auto: Record<string, RGB> } {
  const same = (a?: number[], b?: number[]) => !!a && !!b && a.every((v, i) => v === b[i]);
  const patch: Record<string, { color?: RGB }> = {};
  const next: Record<string, RGB> = {};
  for (const k of clusterLevels) {
    const cur = clusterStyles[k]?.color;
    const mine = auto[k];
    const byHand = cur != null && !same(cur, mine);
    if (byHand) continue;
    const lab = labels[k]?.trim();
    const t = lab ? typeLevels.indexOf(lab) : -1;
    if (t >= 0) {
      const c = (typeStyles[lab!]?.color ?? palette[t % palette.length]).slice(0, 3) as RGB;
      next[k] = c;
      if (!same(cur, c)) patch[k] = { color: c };
    } else if (mine) {
      patch[k] = { color: undefined };
    }
  }
  return { patch, auto: next };
}
