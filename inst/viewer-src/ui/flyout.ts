// A flyout from a tools rail button: a panel beside the rail, over the dock,
// for work that takes a while (the Data panel's queue and its pull, a job R
// runs). Unlike the rail's popovers it stays open until its button, its × or
// Escape closes it, never on a click elsewhere, and it keeps its contents
// while closed: built the first time it opens, caught up in show() when it
// opens again.
import type { PanelHandle } from '../panels/dock.ts';

export interface Flyout {
  open(): void;
  close(): void;
  toggle(): void;
  destroy(): void;
}

export function railFlyout(button: HTMLElement, title: string, id: string,
  create: (body: HTMLElement) => PanelHandle): Flyout {
  const el = (cls: string, text = '') => Object.assign(document.createElement('div'), { className: cls, textContent: text });
  const fly = el('flyout');
  const head = el('flyout-head');
  const x = Object.assign(document.createElement('button'), { className: 'flyout-close', textContent: '×', title: 'close' });
  head.append(el('flyout-title', title), x);
  const body = el('flyout-body');
  body.dataset.panel = id;   // a hook for tests, as in the dock and the tray
  fly.append(head, body);
  let handle: PanelHandle | null = null;

  // Level with its button, down to the bottom bar
  const place = () => {
    const r = button.getBoundingClientRect();
    fly.style.left = `${r.right + 6}px`;
    fly.style.top = `${Math.max(4, r.top)}px`;
  };
  const keys = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
  function open() {
    if (fly.isConnected) return;
    document.body.append(fly);
    place();
    button.classList.add('active');
    document.addEventListener('keydown', keys);
    if (!handle) handle = create(body);
    else handle.show?.();
  }
  function close() {
    if (!fly.isConnected) return;
    fly.remove();
    button.classList.remove('active');
    document.removeEventListener('keydown', keys);
  }
  const toggle = () => fly.isConnected ? close() : open();
  x.addEventListener('click', close);
  button.addEventListener('click', toggle);
  window.addEventListener('resize', place);
  return {
    open, close, toggle,
    destroy() { close(); handle?.destroy(); handle = null; window.removeEventListener('resize', place); },
  };
}
