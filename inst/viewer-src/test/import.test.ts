import { describe, it, expect } from 'vitest';
import {
  blankRow, changed, clean, formatSize, initialValues, pathStatus, request,
  type Field, type ImportForm,
} from '../ui/import-model.ts';

const info = (path: string, exists = true) => ({ path, exists, dir: false, size: exists ? 2048 : null });

const bounds: Field = {
  key: 'bounds_path', label: 'Boundaries', group: 'files', type: 'rows', columns: ['name', 'path'],
  value: [{ name: 'cell', path: '/d/cells.parquet', on: true, path_info: info('/d/cells.parquet') }],
  default: [{ name: 'cell', path: '/d/cells.parquet', on: true, path_info: info('/d/cells.parquet') }],
};
const feat: Field = {
  key: 'feat_type', label: 'Feature types', group: 'loading', type: 'rows', columns: ['feat_type', 'keywords'],
  value: [{ feat_type: 'rna', keywords: '' }, { feat_type: 'NegControlProbe', keywords: 'NegControlProbe' }],
  default: [{ feat_type: 'rna', keywords: '' }, { feat_type: 'NegControlProbe', keywords: 'NegControlProbe' }],
};
const qv: Field = { key: 'qv_threshold', label: 'QV', group: 'loading', type: 'number', value: 20, default: 20 };
const form: ImportForm = {
  platform: 'xenium', label: 'Xenium', dir: '/d', info: [], notes: [], fields: [bounds, feat, qv],
  project: '/p/d', snapshot: 'imported', code: '',
};

describe('import form', () => {
  it('copies the values, so editing leaves the form as R sent it', () => {
    const v = initialValues(form);
    (v.bounds_path as any)[0].path = '/other';
    expect((bounds.value as any)[0].path).toBe('/d/cells.parquet');
  });

  it('marks a field changed only when it differs from the reader default', () => {
    const v = initialValues(form);
    expect(changed(bounds, v.bounds_path)).toBe(false);
    (v.bounds_path as any)[0].on = false;
    expect(changed(bounds, v.bounds_path)).toBe(true);
    expect(changed(qv, 20)).toBe(false);
    expect(changed(qv, 30)).toBe(true);
    // feature type rows have no switch: only their text counts
    expect(changed(feat, [{ feat_type: 'rna', keywords: ' ' }, { feat_type: 'NegControlProbe', keywords: 'NegControlProbe', on: false }])).toBe(false);
    expect(changed(feat, [{ feat_type: 'rna', keywords: '' }])).toBe(true);
  });

  it('sends every field without the path info R added', () => {
    const r = request(form, initialValues(form), '/p/x', 'snap', '');
    expect(r).toMatchObject({ platform: 'xenium', dir: '/d', project: '/p/x', snapshot: 'snap' });
    expect(Object.keys(r.values)).toEqual(['bounds_path', 'feat_type', 'qv_threshold']);
    expect((r.values.bounds_path as any)[0]).toEqual({ name: 'cell', path: '/d/cells.parquet', on: true });
    expect(clean(5)).toBe(5);
  });

  it('adds blank rows with a switch only where rows have one', () => {
    expect(blankRow(bounds)).toEqual({ name: '', path: '', on: true });
    expect(blankRow(feat)).toEqual({ feat_type: '', keywords: '' });
  });

  it('shows sizes and file status', () => {
    expect(formatSize(512)).toBe('512 B');
    expect(formatSize(1536)).toBe('1.5 KB');
    expect(formatSize(3 * 1024 ** 3)).toBe('3.0 GB');
    expect(formatSize(null)).toBe('');
    expect(pathStatus(info('/a'), true).cls).toBe('ok');
    expect(pathStatus(info('/a', false), true)).toEqual({ text: 'not found', cls: 'missing' });
    expect(pathStatus(undefined, true).cls).toBe('missing');
    expect(pathStatus(undefined, false).text).toBe('');
  });
});
