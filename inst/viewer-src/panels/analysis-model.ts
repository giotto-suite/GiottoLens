// State of the Analysis panel (launch_lens_analysis()): the tabs (pipelines),
// the step tree and parameter menus R sent, the status of each step, and the marker table with
// the cluster labels. R owns all of it; the panel shows it and sends changes.

export interface Choice { value: string; label: string }
export interface Slider { min: number; max: number; step?: number | null; log?: boolean }
export interface Param {
  id: string; label: string; value: string; choices: Choice[];
  type?: 'choice' | 'number' | 'range' | 'text'; min?: number | null; max?: number | null;
  integer?: boolean; auto?: boolean; slider?: Slider | null; placeholder?: string | null;
  view?: boolean;
}
export interface Step {
  id: string; label: string; fun: string; input: string | null; params: Param[]; pipeline?: string;
}
// A finished run of an analysis, kept by R for the session
export interface HistoryRun { run: number; time: string; label: string; params: string[]; current: boolean }
// An included analysis: its steps run when stale (`auto`) or when Run asks for them
export interface Pipeline {
  id: string; label: string; auto: boolean; steps: string[]; removable?: boolean; history?: HistoryRun[];
}
// An analysis of the Add analysis dialog
export interface CatalogEntry {
  id: string; label: string; brief: string; description: string; inputs: string[];
  outputs: string[]; included: boolean; steps: Step[];
}
// A result table of a step; `data` holds one array per column
export interface ResultTable {
  id: string; title: string; columns: string[]; data: (string | number | boolean | null)[][];
  feat?: string | null; n: number; shown: number; note?: string | null;
}
export interface SavedSettings { name: string; time: string }
export interface Schema {
  disk: boolean; steps: Step[]; cell_markers?: number; settings?: SavedSettings[]; region?: number;
  pipelines?: Pipeline[]; catalog?: CatalogEntry[];
}
export type StatusName = 'stale' | 'queued' | 'running' | 'done' | 'error' | 'blocked';
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
  tables: Record<string, ResultTable[]>;
}

export const emptyModel = (): AnalysisModel => ({
  schema: null, status: {}, markers: [], labels: {}, inherited: {}, suggested: {}, suggestions: [],
  tables: {},
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
  } else if (p.type === 'text') {
    value = value.split(',').map(x => x.trim()).filter(Boolean).join(', ');
  } else if (!p.choices.some(c => c.value === value)) return false;
  if (p.value === value) return false;
  p.value = value;
  if (p.view) return true;
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

// The tabs; one tab with every step when R sent none
export function pipelines(m: AnalysisModel): Pipeline[] {
  const steps = m.schema?.steps ?? [];
  if (m.schema?.pipelines?.length) return m.schema.pipelines;
  return steps.length ? [{ id: 'preprocess', label: 'Preprocessing', auto: true, steps: steps.map(s => s.id) }] : [];
}

export function pipelineSteps(m: AnalysisModel, id: string): Step[] {
  const ids = pipelines(m).find(p => p.id === id)?.steps ?? [];
  return (m.schema?.steps ?? []).filter(s => ids.includes(s.id));
}

// Whether a step runs as soon as it is stale
export function isAuto(m: AnalysisModel, step: string): boolean {
  const p = pipelines(m).find(q => q.steps.includes(step));
  return p ? p.auto : true;
}

// A Run button: for stale or failed steps of a tab that waits for Run
export function canRun(m: AnalysisModel, step: string): boolean {
  const s = m.status[step]?.status ?? 'stale';
  return !isAuto(m, step) && (s === 'stale' || s === 'error');
}

// What is running or waiting, for the panel header (all tabs) or one tab
export function overall(m: AnalysisModel, pipeline?: string): string {
  if (!m.schema) return 'waiting for R…';
  const ids = pipeline ? pipelineSteps(m, pipeline).map(s => s.id) : m.schema.steps.map(s => s.id);
  const st = ids.map(id => ({ id, s: m.status[id]?.status ?? 'stale' }));
  if (st.some(x => x.s === 'running')) return 'running…';
  if (st.some(x => x.s === 'error')) return 'error';
  if (st.some(x => x.s === 'queued' || (x.s === 'stale' && isAuto(m, x.id)))) return 'queued';
  if (st.some(x => x.s === 'stale')) return 'ready to run';
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

// Table rows, filtered by a text (any cell containing it, case-insensitive)
// and sorted by a column; each row is the column values in order
export function tableRows(t: ResultTable, filter = '', sortCol: number | null = null, desc = true) {
  const n = t.data[0]?.length ?? 0;
  let idx = Array.from({ length: n }, (_, i) => i);
  const q = filter.trim().toLowerCase();
  if (q) idx = idx.filter(i => t.data.some(col => String(col[i] ?? '').toLowerCase().includes(q)));
  if (sortCol != null && t.data[sortCol]) {
    const col = t.data[sortCol];
    idx.sort((a, b) => {
      const x = col[a], y = col[b];
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y));
      return desc ? -c : c;
    });
  }
  return idx.map(i => t.data.map(col => col[i]));
}

// Parameter values chosen in the Add analysis dialog, as R takes them
export function draftParams(entry: CatalogEntry, draft: Record<string, Record<string, string>>) {
  const out: Record<string, Record<string, string>> = {};
  for (const st of entry.steps) for (const p of st.params) {
    const v = draft[st.id]?.[p.id];
    if (v != null && v !== p.value) (out[st.id] ??= {})[p.id] = v;
  }
  return out;
}
