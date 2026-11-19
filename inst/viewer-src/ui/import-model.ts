// The import form's data (adr/0027): R detects a dataset folder and answers
// the form (`import_detect`); the page edits the values and sends them back
// (`import_code`, `import_run`). No DOM here; ui/import.ts draws the form.

export interface PathInfo { path: string; exists: boolean; dir: boolean; size: number | null }

export type Row = Record<string, string | boolean | PathInfo | undefined> & { on?: boolean };

export type FieldValue = string | number | boolean | Row[];

export interface Field {
  key: string;
  label: string;
  group: 'files' | 'images' | 'loading';
  type: 'path' | 'rows' | 'bool' | 'number' | 'text';
  value: FieldValue;
  default: FieldValue;
  help?: string | null;
  info?: PathInfo;              // a path field's file
  columns?: string[];           // a rows field's text columns
  min?: number;
}

export interface ImportForm {
  platform: string;
  label: string;
  dir: string;
  info: { label: string; value: string }[];
  notes: string[];
  fields: Field[];
  project: string;
  snapshot: string;
  code: string;
  problem?: string;
}

export const GROUPS: { id: Field['group']; title: string }[] = [
  { id: 'files', title: 'Files' },
  { id: 'images', title: 'Images' },
  { id: 'loading', title: 'Loading' },
];

// Columns holding paths, whose rows get a file status
export const PATH_COLUMNS = new Set(['path', 'alignment']);

// Rows a field's rows can be switched off in (the others have no `on`)
export const togglable = (f: Field): boolean => f.key !== 'feat_type';

const strip = (r: Row): Row => {
  const out: Row = {};
  for (const [k, v] of Object.entries(r)) if (!k.endsWith('_info')) out[k] = v;
  return out;
};

// A value without what R added for display (path info), as R takes it
export function clean(v: FieldValue): FieldValue {
  return Array.isArray(v) ? v.map(strip) : v;
}

// The values to edit, from the form: a copy, so the form keeps R's
export function initialValues(form: ImportForm): Record<string, FieldValue> {
  const out: Record<string, FieldValue> = {};
  for (const f of form.fields) out[f.key] = Array.isArray(f.value) ? f.value.map(r => ({ ...r })) : f.value;
  return out;
}

const canon = (f: Field, v: FieldValue): string => {
  if (!Array.isArray(v)) return JSON.stringify(v);
  const rows = (v as Row[]).map(strip).filter(r => !togglable(f) || r.on !== false)
    .map(r => (f.columns ?? []).map(c => String(r[c] ?? '').trim()));
  return JSON.stringify(rows);
};

// Whether a field's value differs from the reader's default: R passes the
// reader only those
export function changed(f: Field, v: FieldValue): boolean {
  if (f.type === 'number') return Number(v) !== Number(f.default);
  return canon(f, v) !== canon(f, f.default);
}

// What import_code / import_run send
// `analyze`: start Preprocessing when the imported snapshot opens
export function request(form: ImportForm, values: Record<string, FieldValue>,
  project: string, snapshot: string, description: string, analyze = false) {
  const vals: Record<string, FieldValue> = {};
  for (const f of form.fields) vals[f.key] = clean(values[f.key] ?? f.value);
  return { platform: form.platform, dir: form.dir, values: vals, project, snapshot, description, analyze };
}

// An empty row for a rows field
export function blankRow(f: Field): Row {
  const r: Row = {};
  for (const c of f.columns ?? []) r[c] = '';
  if (togglable(f)) r.on = true;
  return r;
}

export function formatSize(n: number | null | undefined): string {
  if (n == null || !isFinite(n)) return '';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n < 10 && i ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
}

// A path's status as the form shows it
export function pathStatus(info: PathInfo | undefined, needed: boolean): { text: string; cls: string } {
  if (!info || !info.path) return needed ? { text: 'none', cls: 'missing' } : { text: '', cls: '' };
  if (!info.exists) return { text: 'not found', cls: 'missing' };
  return { text: '\u2713 ' + formatSize(info.size), cls: 'ok' };
}
