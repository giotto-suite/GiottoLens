// One window shows the viewer (adr/0028). This is what the others show: the
// code to give R (viewer$allow(code)) while waiting, or that the viewer moved
// away. In the window that shows the viewer, a bar takes the code of a
// window that waits and moves the viewer to it.
import { askR, onGate, onMessage, requestViewer } from '../core/comms.js';

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text = ''): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  e.className = className;
  e.textContent = text;
  return e;
}

let _started = false;
export function initGate(): void {
  if (_started) return;
  _started = true;

  const cover = el('div', 'gate');
  const box = el('div', 'gate-box');
  const title = el('div', 'gate-title');
  const code = el('div', 'gate-code');
  const text = el('div', 'gate-text');
  const use = el('button', 'gate-btn', 'show the viewer here');
  use.addEventListener('click', requestViewer);
  box.append(title, code, text, use);
  cover.append(box);
  document.body.append(cover);

  onGate((g: { state: string; code?: string }) => {
    cover.classList.toggle('visible', g.state !== 'granted' && g.state !== 'connecting');
    code.textContent = g.state === 'waiting' ? String(g.code ?? '') : '';
    use.hidden = g.state !== 'released';
    if (g.state === 'waiting') {
      title.textContent = 'This window is waiting for the viewer';
      text.textContent = `In R, run viewer$allow(${g.code ?? ''}). ` +
        'Or type this code in the window that shows the viewer.';
    } else if (g.state === 'released') {
      title.textContent = 'The viewer moved to another window';
      text.textContent = '';
    } else if (g.state === 'closed') {
      title.textContent = 'The viewer is stopped';
      text.textContent = 'launch_lens() starts a new one.';
    }
  });

  // Windows are waiting: a bar to type the code one of them shows. R sends
  // how many wait, never their codes, and checks the code typed.
  const bar = el('form', 'claim-bar');
  const input = el('input', 'claim-code');
  Object.assign(input, { type: 'text', inputMode: 'numeric', maxLength: 4, autocomplete: 'off',
    placeholder: 'code', title: 'the code the waiting window shows' });
  const move = el('button', 'gate-btn', 'move the viewer there');
  move.type = 'submit';
  const keep = el('button', 'gate-btn', 'keep it here');
  keep.type = 'button';
  const note = el('span', 'claim-note');
  bar.append(el('span', 'claim-text', 'Another window asks to show the viewer. Type the code it shows:'),
    input, move, keep, note);
  document.body.append(bar);

  let waiting = 0;
  const show = (on: boolean) => {
    bar.classList.toggle('visible', on);
    if (!on) { input.value = ''; note.textContent = ''; }
  };
  onMessage('claim_request', ({ waiting: n }: { waiting: number }) => {
    // A new request shows the bar again; one withdrawn leaves it as it is
    if (n > waiting) show(true);
    if (n === 0) show(false);
    waiting = n;
  });
  keep.addEventListener('click', () => show(false));
  bar.addEventListener('submit', e => {
    e.preventDefault();
    const code = input.value.trim();
    if (!code) { note.textContent = 'type the code first'; return; }
    note.textContent = '';
    askR('claim', { code }).catch((err: Error) => { note.textContent = err.message; });
  });
  onGate((g: { state: string }) => { if (g.state !== 'granted') { waiting = 0; show(false); } });
}
