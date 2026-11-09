// The register panel: pick an image and a reference, start the landmark tool
// (ui/registration.ts), orient the image's pane, preview and link, and the
// pairs with their residuals (adr/0014).
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import { MOVING_COLOR, FIXED_COLOR } from '../render/landmarks.ts';
import { registrationFit, completePairs, MIN_PAIRS } from '../data/registration.ts';
import { registering, pending, startRegistration, flipImage, rotateImage, onMainView } from '../ui/registration.ts';
import { createIcons, icons } from 'lucide';
import type { PanelHandle } from './dock.ts';

const css = ([r, g, b]: number[]) => `rgb(${r},${g},${b})`;
const el = <K extends keyof HTMLElementTagNameMap>(tag: K, props: object = {}): HTMLElementTagNameMap[K] =>
  Object.assign(document.createElement(tag), props);

function options(sel: HTMLSelectElement, names: string[], none: string | null) {
  sel.replaceChildren(...[...(none != null ? [['', none]] : []), ...names.map(n => [n, n])].map(([v, t]) =>
    el('option', { value: v, textContent: t })));
}

export function createRegisterPanel(body: HTMLElement): PanelHandle {
  const names = [...state.images.keys()] as string[];
  const root = el('div', { className: 'ctl-body reg-body' });
  const row = (label: string, input: HTMLElement) => {
    const r = el('div', { className: 'alpha-row' });
    r.append(el('label', { textContent: label }), input);
    return r;
  };
  const check = (label: string, cls: string) => {
    const input = el('input', { type: 'checkbox', className: cls });
    const r = el('label', { className: 'alpha-row check-row' });
    r.append(input, el('span', { textContent: label }));
    return { r, input };
  };
  const button = (cls: string, title: string, icon?: string) => {
    const b = el('button', { className: cls, title });
    if (icon) b.innerHTML = `<i data-lucide="${icon}"></i>`;
    return b;
  };
  const $image = el('select', { className: 'ctl-select reg-image' });
  const $ref = el('select', { className: 'ctl-select reg-reference' });
  const $start = el('button', { className: 'reg-start', textContent: 'start' });
  const orient = [
    button('reg-flip-h', "flip the image's pane left-right", 'flip-horizontal-2'),
    button('reg-flip-v', "flip the image's pane top-bottom", 'flip-vertical-2'),
    button('reg-rot-ccw', "turn the image's pane 90° counterclockwise", 'rotate-ccw'),
    button('reg-rot-cw', "turn the image's pane 90° clockwise", 'rotate-cw'),
  ];
  const $reset = el('button', { className: 'reg-reset', title: 'discard the registration', textContent: 'reset' });
  const btns = el('div', { className: 'reg-actions' });
  btns.append($start, ...orient, $reset);
  const preview = check('preview on reference', 'reg-preview');
  const link = check('link views', 'reg-link');
  const $status = el('div', { className: 'reg-status' });
  const $list = el('div', { className: 'reg-list' });
  root.append(row('image', $image), row('reference', $ref), btns, preview.r, link.r, $status, $list);
  body.append(root);
  createIcons({ icons, root: btns });

  options($image, names, null);
  // Default: the first RGB image (an H&E) against the first other image
  const rgb = names.find(n => state.images.get(n).rgb);
  $image.value = rgb ?? names[names.length - 1];
  const refFor = (img: string) => names.find(n => n !== img && !state.images.get(n).rgb) ?? names.find(n => n !== img) ?? '';
  const fillRef = () => { options($ref, names.filter(n => n !== $image.value), 'none'); $ref.value = refFor($image.value); };
  fillRef();
  $image.addEventListener('change', fillRef);

  $start.addEventListener('click', () => {
    const s = store.getState();
    if (s.mode === 'landmark') { actions.setMode('pan'); return; }
    if (!s.registration || s.registration.image !== $image.value || s.registration.reference !== ($ref.value || null))
      startRegistration($image.value, $ref.value || null);
    actions.setMode('landmark');
  });
  $reset.addEventListener('click', () => {
    actions.setRegistration(null);
    if (store.getState().mode === 'landmark') actions.setMode('pan');
  });
  orient[0].addEventListener('click', () => flipImage('h'));
  orient[1].addEventListener('click', () => flipImage('v'));
  orient[2].addEventListener('click', () => rotateImage(1));
  orient[3].addEventListener('click', () => rotateImage(-1));
  preview.input.addEventListener('change', () => actions.patchRegistration({ preview: preview.input.checked }));
  link.input.addEventListener('change', () => {
    actions.patchRegistration({ link: link.input.checked });
    if (link.input.checked && state.currentViewState) onMainView(state.currentViewState);
  });

  const render = () => {
    const s = store.getState();
    const reg = s.registration;
    const active = registering();
    $start.textContent = active ? 'done' : reg ? 'place points' : 'start';
    $start.classList.toggle('active', active);
    $image.disabled = $ref.disabled = active;
    if (reg) { $image.value = reg.image; if (!active) { fillRef(); $ref.value = reg.reference ?? ''; } }
    const fit = reg ? registrationFit(reg) : null;
    for (const b of orient) b.disabled = !active;
    $reset.disabled = !reg;
    preview.input.checked = !!reg?.preview;
    preview.input.disabled = !reg;
    link.input.checked = !!reg?.link;
    link.input.disabled = !fit;

    const done = reg ? completePairs(reg).length : 0;
    const open = reg && pending(reg);
    const fixedName = reg?.reference ?? 'the data';
    $status.textContent = !reg ? 'pick an image and a reference, then start'
      : open ? (open.moving ? `click the matching point on ${fixedName} (right)` : `click the matching point on ${reg.image} (left)`)
      : fit ? `${done} pairs · RMSE ${fit.rmse.toFixed(2)} μm`
      : active ? `click a point in either pane · ${done}/${MIN_PAIRS} pairs for a fit`
      : `${done}/${MIN_PAIRS} pairs for a fit`;

    $list.replaceChildren();
    if (!reg) return;
    let k = 0;
    reg.landmarks.forEach((l, i) => {
      const r = el('div', { className: 'reg-row' });
      const dot = (on: boolean, c: number[]) => `<span class="reg-dot" style="${on ? `background:${css(c)}` : ''};border-color:${css(c)}"></span>`;
      const res = l.moving && l.fixed && fit ? fit.residuals[k++] : null;
      r.innerHTML = `<span class="reg-n">${i + 1}</span>${dot(!!l.moving, MOVING_COLOR)}${dot(!!l.fixed, FIXED_COLOR)}` +
        `<span class="reg-res">${res != null ? `${res.toFixed(2)} μm` : ''}</span>` +
        `<button class="annot-row-btn" title="delete"><i data-lucide="x"></i></button>`;
      r.querySelector('button')!.addEventListener('click', () => actions.removeLandmark(l.id));
      $list.appendChild(r);
    });
    createIcons({ icons, root: $list });
  };
  render();
  const unsub = store.subscribe(s => [s.registration, s.mode], render,
    { equalityFn: (a, b) => a[0] === b[0] && a[1] === b[1] });

  return { destroy: unsub };
}
