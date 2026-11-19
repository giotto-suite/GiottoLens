// The start page's import form (adr/0027): a platform and a dataset folder;
// R detects it with Giotto's reader (`import_detect`) and the form shows
// every argument of the import filled in, to edit. Import runs as a job
// (`import_run`, answered when it ends); its progress comes as `job`
// messages with the form's `ref`. The page then opens the snapshot.
// @ts-ignore: plain JS module
import { askR } from '../core/comms.js';
import { onJobs, runningJobs } from './jobs.ts';
import {
  GROUPS, PATH_COLUMNS, blankRow, changed, initialValues, pathStatus, request, togglable,
  type Field, type FieldValue, type ImportForm, type PathInfo, type Row,
} from './import-model.ts';

const PLATFORMS = [{ id: 'xenium', label: 'Xenium' }];

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

function button(text: string, onClick: () => void, cls = 'start-btn'): HTMLButtonElement {
  const b = el('button', cls, text);
  b.type = 'button';
  b.addEventListener('click', onClick);
  return b;
}

function input(value: string, cls = 'start-input', placeholder = ''): HTMLInputElement {
  const i = el('input', cls);
  i.value = value;
  i.placeholder = placeholder;
  i.spellcheck = false;
  i.autocomplete = 'off';
  return i;
}

// A status span for a path, refreshed from R (`import_paths`) after an edit
function pathCell(get: () => string, info: PathInfo | undefined, needed: () => boolean) {
  const span = el('span', 'imp-status');
  let last = info;
  const draw = () => {
    const s = pathStatus(last, needed());
    span.textContent = s.text;
    span.className = 'imp-status ' + s.cls;
    span.title = last?.path ?? '';
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const refresh = () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const p = get().trim();
      if (!p) { last = undefined; draw(); return; }
      try { [last] = await askR('import_paths', { paths: [p] }); } catch { last = undefined; }
      draw();
    }, 350);
  };
  draw();
  return { span, refresh, draw };
}

// Opens the import form in `body`. `back` returns to the projects list;
// `openSnapshot` opens what was imported.
export function showImport(root: HTMLElement, body: HTMLElement, back: () => void,
  openSnapshot: (path: string, name: string) => void, browse: boolean) {
  const status = root.querySelector('.start-status') as HTMLElement;
  const say = (text: string, error = false) => {
    status.textContent = text;
    status.classList.toggle('error', error);
  };
  say('');

  const head = el('div', 'start-head');
  head.append(button('\u2190 Projects', back, 'start-link'));
  const platform = el('select', 'start-select');
  for (const p of PLATFORMS) platform.append(new Option(p.label, p.id));
  const dir = input('', 'start-input', 'dataset folder\u2026');
  const pick = el('form', 'start-open');
  pick.append(platform, dir, el('button', 'start-btn', 'Detect'));
  if (browse) pick.append(button('Browse\u2026', async () => {
    try {
      const { path } = await askR('browse', { purpose: 'dataset' });
      if (path) { dir.value = path; detect(); }
    } catch (e: any) { say(e.message, true); }
  }));
  const formHost = el('div', 'imp-form');
  body.replaceChildren(head, el('div', 'start-label', 'Import a dataset'), pick, formHost);
  pick.addEventListener('submit', ev => { ev.preventDefault(); detect(); });
  dir.focus();

  async function detect() {
    const d = dir.value.trim();
    if (!d) return;
    say('detecting\u2026');
    root.classList.add('busy');
    try {
      const form: ImportForm = await askR('import_detect', { platform: platform.value, dir: d });
      say('');
      drawForm(form);
    } catch (e: any) {
      formHost.replaceChildren();
      say(e.message, true);
    } finally {
      root.classList.remove('busy');
    }
  }

  function drawForm(form: ImportForm) {
    const values = initialValues(form);
    const marks = new Map<string, HTMLElement>();
    const mark = (f: Field) => marks.get(f.key)?.classList.toggle('edited', changed(f, values[f.key]));
    const set = (f: Field, v: FieldValue) => { values[f.key] = v; mark(f); };
    // A path field is needed while its load switch is on
    const LOADS: Record<string, string> = {
      transcript_path: 'load_transcripts', expression_path: 'load_expression',
      cell_metadata_path: 'load_cellmeta',
    };
    const needed = (k: string) => () => (LOADS[k] ? values[LOADS[k]] === true : false);
    const redraws: (() => void)[] = [];

    const parts: HTMLElement[] = [];
    parts.push(el('div', 'imp-dir', form.dir));
    if (form.info.length) {
      const info = el('div', 'imp-info');
      for (const i of form.info) {
        const b = el('span', 'imp-chip');
        b.append(el('span', 'imp-chip-k', i.label), ' ' + i.value);
        info.append(b);
      }
      parts.push(info);
    }
    if (form.problem) parts.push(el('div', 'imp-problem', form.problem));

    for (const g of GROUPS) {
      const fields = form.fields.filter(f => f.group === g.id);
      if (!fields.length) continue;
      parts.push(el('div', 'start-label', g.title));
      const grid = el('div', 'imp-grid');
      for (const f of fields) {
        const lab = el('label', 'imp-label', f.label);
        if (f.help) lab.title = f.help;
        marks.set(f.key, lab);
        grid.append(lab, fieldControl(f));
        mark(f);
      }
      parts.push(grid);
    }

    function fieldControl(f: Field): HTMLElement {
      const cell = el('div', 'imp-cell');
      if (f.type === 'path' || f.type === 'text') {
        const i = input(String(values[f.key] ?? ''));
        cell.append(i);
        if (f.type === 'path') {
          const st = pathCell(() => i.value, f.info, needed(f.key));
          redraws.push(st.draw);
          cell.append(st.span);
          i.addEventListener('input', () => { set(f, i.value); st.refresh(); });
        } else i.addEventListener('input', () => set(f, i.value));
      } else if (f.type === 'number') {
        const i = input(String(values[f.key]), 'start-input imp-num');
        i.type = 'number';
        if (f.min != null) i.min = String(f.min);
        i.addEventListener('input', () => set(f, i.value === '' ? NaN : Number(i.value)));
        cell.append(i);
      } else if (f.type === 'bool') {
        const c = el('input');
        c.type = 'checkbox';
        c.checked = values[f.key] === true;
        c.addEventListener('change', () => { set(f, c.checked); redraws.forEach(fn => fn()); });
        cell.append(c);
      } else if (f.type === 'rows') {
        cell.classList.add('rows');
        drawRows(f, cell);
      }
      return cell;
    }

    function drawRows(f: Field, cell: HTMLElement) {
      const rows = values[f.key] as Row[];
      const cols = f.columns ?? [];
      const redraw = () => { cell.replaceChildren(); drawRows(f, cell); mark(f); };
      for (const [i, r] of rows.entries()) {
        const line = el('div', 'imp-row' + (r.on === false ? ' off' : ''));
        if (togglable(f)) {
          const c = el('input');
          c.type = 'checkbox';
          c.checked = r.on !== false;
          c.title = 'load';
          c.addEventListener('change', () => { r.on = c.checked; line.classList.toggle('off', !c.checked); mark(f); });
          line.append(c);
        }
        for (const col of cols) {
          const v = input(String(r[col] ?? ''), 'start-input imp-col imp-col-' + col, col);
          line.append(v);
          if (PATH_COLUMNS.has(col)) {
            const st = pathCell(() => v.value, r[col + '_info'] as PathInfo | undefined, () => r.on !== false);
            line.append(st.span);
            v.addEventListener('input', () => { r[col] = v.value; delete r[col + '_info']; mark(f); st.refresh(); });
          } else v.addEventListener('input', () => { r[col] = v.value; mark(f); });
        }
        line.append(button('\u00d7', () => { rows.splice(i, 1); redraw(); }, 'annot-row-btn imp-del'));
        cell.append(line);
      }
      cell.append(button('+ add', () => { rows.push(blankRow(f)); redraw(); }, 'start-link imp-add'));
    }

    // Project
    parts.push(el('div', 'start-label', 'Project'));
    const pgrid = el('div', 'imp-grid');
    const project = input(form.project);
    const snapshot = input(form.snapshot);
    const desc = input('', 'start-input', 'optional');
    const analyze = el('input');
    analyze.type = 'checkbox';
    analyze.checked = true;
    const analyzeCell = el('div', 'imp-cell');
    analyzeCell.append(analyze);
    const analyzeLab = el('label', 'imp-label', 'Run Preprocessing');
    analyzeLab.title = 'start the Analysis panel\'s Preprocessing when the imported snapshot opens';
    pgrid.append(el('label', 'imp-label', 'Project folder'), project,
      el('label', 'imp-label', 'Snapshot'), snapshot,
      el('label', 'imp-label', 'Description'), desc,
      analyzeLab, analyzeCell);
    parts.push(pgrid);

    // The reader's messages and the R code
    if (form.notes.length) {
      const d = el('details', 'imp-details');
      d.append(el('summary', '', `Reader messages (${form.notes.length})`));
      const ul = el('ul', 'imp-notes');
      for (const n of form.notes) ul.append(el('li', '', n));
      d.append(ul);
      parts.push(d);
    }
    const code = el('details', 'imp-details');
    const pre = el('pre', 'imp-code', form.code);
    code.append(el('summary', '', 'R code'), pre);
    const req = () => request(form, values, project.value.trim(), snapshot.value.trim(), desc.value.trim(),
      analyze.checked);
    code.addEventListener('toggle', async () => {
      if (!code.open) return;
      try { pre.textContent = (await askR('import_code', req())).code; pre.classList.remove('error'); }
      catch (e: any) { pre.textContent = e.message; pre.classList.add('error'); }
    });
    parts.push(code);

    // Import, with the job's progress
    const act = el('div', 'start-actions imp-actions');
    const go = button('Import', run, 'start-btn primary');
    const cancel = button('Cancel', () => {
      const j = runningJobs().find(x => x.ref === ref);
      if (j) askR('cancel_job', { id: j.id }).catch(() => {});
    });
    cancel.hidden = true;
    const progress = el('span', 'start-sub imp-progress');
    act.append(go, cancel, progress);
    parts.push(act);
    formHost.replaceChildren(...parts);

    let ref = '';
    let off: (() => void) | null = null;
    async function run() {
      ref = `import-${Date.now()}`;
      go.disabled = true;
      cancel.hidden = false;
      formHost.classList.add('running');
      say('importing\u2026');
      off = onJobs(() => {
        const j = runningJobs().find(x => x.ref === ref);
        if (j?.progress?.what) progress.textContent = j.progress.what;
      });
      try {
        const r = await askR('import_run', { ...req(), ref });
        say(`imported into ${r.path}`);
        openSnapshot(r.path, r.name);
      } catch (e: any) {
        say(e.code === 'cancelled' ? 'import cancelled' : e.message, e.code !== 'cancelled');
      } finally {
        off?.();
        go.disabled = false;
        cancel.hidden = true;
        progress.textContent = '';
        formHost.classList.remove('running');
      }
    }
  }
}
