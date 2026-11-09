import { describe, it, expect } from 'vitest';
import {
  emptyModel, descendants, applyParam, clusterRows, labelPayload, statusText, overall,
  numberKey, rangeKey, sliderPos, sliderValue, clusterColorPatch,
  type Step, type AnalysisModel, type Param,
} from '../panels/analysis-model.ts';

const steps: Step[] = [
  { id: 'filter', label: 'QC filter', fun: 'filterGiotto', input: null,
    params: [{ id: 'min_det_feats_per_cell', label: 'min', value: '100',
      choices: [{ value: '10', label: '10' }, { value: '100', label: '100' }] }] },
  { id: 'normalize', label: 'Normalize', fun: 'normalizeGiotto', input: 'filter', params: [] },
  { id: 'pca', label: 'PCA', fun: 'runPCA', input: 'normalize', params: [] },
  { id: 'umap', label: 'UMAP', fun: 'runUMAP', input: 'pca',
    params: [{ id: 'min_dist', label: 'min dist', value: '0.05',
      choices: [{ value: '0.05', label: '0.05' }, { value: '0.3', label: '0.3' }] }] },
  { id: 'network', label: 'NN', fun: 'createNearestNetwork', input: 'pca', params: [] },
  { id: 'leiden', label: 'Leiden', fun: 'doLeidenCluster', input: 'network', params: [] },
];

function model(): AnalysisModel {
  const m = emptyModel();
  m.schema = { disk: true, steps: structuredClone(steps) };
  for (const s of steps) m.status[s.id] = { status: 'done', secs: 0.5 };
  return m;
}

describe('descendants', () => {
  it('follows the tree below a step, not its siblings', () => {
    expect(descendants(steps, 'umap')).toEqual(['umap']);
    expect(descendants(steps, 'pca').sort()).toEqual(['leiden', 'network', 'pca', 'umap']);
    expect(descendants(steps, 'filter')).toHaveLength(steps.length);
  });
});

describe('applyParam', () => {
  it('marks the step and those below it stale', () => {
    const m = model();
    expect(applyParam(m, 'umap', 'min_dist', '0.3')).toBe(true);
    expect(m.status.umap.status).toBe('stale');
    expect(m.status.leiden.status).toBe('done');
    expect(m.schema!.steps.find(s => s.id === 'umap')!.params[0].value).toBe('0.3');
  });
  it('reruns everything after an upstream change', () => {
    const m = model();
    applyParam(m, 'filter', 'min_det_feats_per_cell', '10');
    expect(Object.values(m.status).every(s => s.status === 'stale')).toBe(true);
  });
  it('ignores unknown values and unchanged values', () => {
    const m = model();
    expect(applyParam(m, 'umap', 'min_dist', '7')).toBe(false);
    expect(applyParam(m, 'umap', 'nope', '0.3')).toBe(false);
    expect(applyParam(m, 'umap', 'min_dist', '0.05')).toBe(false);
    expect(m.status.umap.status).toBe('done');
  });
});

describe('clusters and labels', () => {
  it('orders clusters numerically and keeps marker order', () => {
    const m = model();
    m.markers = [
      { cluster: '10', feat: 'EPCAM', score: 2 }, { cluster: '2', feat: 'COL1A1', score: 3 },
      { cluster: '2', feat: 'DCN', score: 1 }, { cluster: '1', feat: 'CD3E', score: 1 },
    ];
    m.labels = { '2': 'fibroblast' };
    const rows = clusterRows(m);
    expect(rows.map(r => r.cluster)).toEqual(['1', '2', '10']);
    expect(rows[1]).toEqual({ cluster: '2', feats: ['COL1A1', 'DCN'], label: 'fibroblast' });
  });
  it('sends only non-empty, trimmed labels', () => {
    expect(labelPayload({ '1': ' T cell ', '2': '', '3': '  ' })).toEqual({ '1': 'T cell' });
  });
});

describe('status text', () => {
  it('summarises steps and the panel', () => {
    expect(statusText({ status: 'done', secs: 1.234 })).toBe('done 1.2 s');
    expect(statusText(undefined)).toBe('stale');
    const m = model();
    expect(overall(m)).toBe('up to date');
    m.status.umap = { status: 'running' };
    expect(overall(m)).toBe('running…');
    expect(overall(emptyModel())).toBe('waiting for R…');
  });
});

describe('number parameters', () => {
  const res: Param = { id: 'resolution', label: 'resolution', value: '1', type: 'number',
    min: 0.001, max: null, integer: false, auto: false, choices: [{ value: '1', label: '1' }] };
  const pcs: Param = { id: 'k', label: 'k', value: '10', type: 'number',
    min: 2, integer: true, choices: [] };
  const nn: Param = { id: 'n_neighbors', label: 'neighbors', value: 'auto', type: 'number',
    min: 2, integer: true, auto: true, choices: [] };
  it('takes any value in range, not only the suggestions', () => {
    expect(numberKey(res, '0.37')).toBe('0.37');
    expect(numberKey(res, ' 2 ')).toBe('2');
    expect(numberKey(pcs, '17')).toBe('17');
  });
  it('rejects text, out-of-range and fractional values', () => {
    expect(numberKey(res, 'abc')).toBeNull();
    expect(numberKey(res, '0')).toBeNull();
    expect(numberKey(pcs, '1')).toBeNull();
    expect(numberKey(pcs, '12.5')).toBeNull();
    expect(numberKey(res, '')).toBeNull();
  });
  it('maps an empty box to auto where allowed', () => {
    expect(numberKey(nn, '')).toBe('auto');
    expect(numberKey(nn, '25')).toBe('25');
  });
  it('applies a typed value and marks the step below stale', () => {
    const m = model();
    m.schema!.steps.find(s => s.id === 'umap')!.params.push(structuredClone(pcs));
    expect(applyParam(m, 'umap', 'k', '17')).toBe(true);
    expect(m.status.umap.status).toBe('stale');
    expect(applyParam(m, 'umap', 'k', '1.5')).toBe(false);
  });
});

describe('carried-over labels', () => {
  it('are reported per cluster', () => {
    const m = model();
    m.markers = [{ cluster: '1', feat: 'EPCAM', score: 2 }, { cluster: '2', feat: 'DCN', score: 1 }];
    m.labels = { '1': 'epithelial' };
    m.inherited = { '1': { from: '3', share: 0.8 } };
    const rows = clusterRows(m);
    expect(rows[0].inherited).toEqual({ from: '3', share: 0.8 });
    expect(rows[1].inherited).toBeUndefined();
  });
});

describe('PC ranges', () => {
  const r: Param = { id: 'dimensions_to_use', label: 'PCs', value: '1:10', type: 'range',
    min: 1, max: 38, integer: true, choices: [] };
  it('takes from:to with from < to within the PCs', () => {
    expect(rangeKey(r, '2:15')).toBe('2:15');
    expect(rangeKey(r, ' 3 : 30 ')).toBe('3:30');
    expect(rangeKey(r, '0:10')).toBeNull();
    expect(rangeKey(r, '10:10')).toBeNull();
    expect(rangeKey(r, '5:39')).toBeNull();
    expect(rangeKey(r, '10')).toBeNull();
  });
  it('applies a range that skips PC 1', () => {
    const m = model();
    m.schema!.steps.find(s => s.id === 'umap')!.params.push(structuredClone(r));
    expect(applyParam(m, 'umap', 'dimensions_to_use', '2:15')).toBe(true);
    expect(m.status.umap.status).toBe('stale');
    expect(m.status.leiden.status).toBe('done');
  });
});

describe('slider mapping', () => {
  it('rounds linear sliders to their step and maps log sliders', () => {
    expect(sliderValue({ min: 0, max: 5, step: 0.1 }, 1.2300001)).toBe(1.2);
    expect(sliderValue({ min: 0, max: 300, step: 1 }, 42.4, true)).toBe(42);
    const lg = { min: 0.01, max: 5, log: true };
    expect(sliderPos(lg, 1)).toBe(0);
    expect(sliderValue(lg, Math.log10(0.37))).toBe(0.37);
    expect(sliderValue(lg, sliderPos(lg, 6000))).toBe(6000);
  });
});

describe('suggested labels', () => {
  it("mark suggested rows and carry each cluster's suggestion", () => {
    const m = model();
    m.markers = [{ cluster: '1', feat: 'EPCAM', score: 2 }, { cluster: '2', feat: 'DCN', score: 1 }];
    m.labels = { '1': 'Epithelial', '2': 'stroma' };
    m.suggested = { '1': { type: 'Epithelial', share: 0.9 } };
    m.suggestions = [{ cluster: '1', type: 'Epithelial', share: 0.9 }, { cluster: '2', type: 'Fibroblast', share: 0.4 }];
    const rows = clusterRows(m);
    expect(rows[0].suggested).toBe(true);
    expect(rows[1].suggested).toBeUndefined();
    expect(rows[1].suggestion).toEqual({ cluster: '2', type: 'Fibroblast', share: 0.4 });
  });
});

describe('cluster colors follow labels', () => {
  const pal = [[1, 1, 1], [2, 2, 2], [3, 3, 3], [4, 4, 4]];
  it('gives clusters with the same label the color of that label', () => {
    const { patch, auto } = clusterColorPatch({ '1': 'T cell', '3': 'T cell', '2': 'B cell' },
      ['1', '2', '3', '4'], ['B cell', 'T cell', '4'], {}, {}, pal, {});
    expect(patch['1'].color).toEqual([2, 2, 2]);
    expect(patch['3'].color).toEqual([2, 2, 2]);
    expect(patch['2'].color).toEqual([1, 1, 1]);
    expect(patch['4']).toBeUndefined();
    expect(Object.keys(auto).sort()).toEqual(['1', '2', '3']);
  });
  it('uses a color set for the label and keeps colors set by hand', () => {
    const { patch } = clusterColorPatch({ '1': 'T cell', '2': 'T cell' }, ['1', '2'], ['T cell'],
      { 'T cell': { color: [9, 9, 9] } }, { '2': { color: [7, 7, 7] } }, pal, {});
    expect(patch['1'].color).toEqual([9, 9, 9]);
    expect(patch['2']).toBeUndefined();
  });
  it('returns a cluster to its own color when its label goes', () => {
    const { patch, auto } = clusterColorPatch({}, ['1'], ['T cell'], {}, { '1': { color: [2, 2, 2] } },
      pal, { '1': [2, 2, 2] });
    expect(patch['1']).toEqual({ color: undefined });
    expect(auto).toEqual({});
  });
});
