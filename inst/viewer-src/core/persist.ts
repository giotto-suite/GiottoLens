// The config outlives a page reload through R: the page sends it on every
// change (merged over SAVE_DELAY ms, an identical copy dropped), R keeps the
// latest, and R sends it back when a page connects ('restore'). R holds it
// rather than browser storage because it outlives the page, it re-pushes the
// panels the layout names, and a later save to file starts from its copy.
// zustand's persist middleware (core/store.ts) decides what is saved and when;
// this is its storage (adr/0009).
import type { PersistStorage, StorageValue } from 'zustand/middleware';
import { onMessage, sendToR } from './comms.js';

const SAVE_DELAY = 300;

let restored = false;
let held: Set<string> | null = null;
let resolve: (v: StorageValue<unknown> | null) => void = () => {};
const saved = new Promise<StorageValue<unknown> | null>(r => { resolve = r; });
let timer: ReturnType<typeof setTimeout> | undefined;
let pending: StorageValue<unknown> | null = null;
let lastSent = '';

function flush() {
  const json = JSON.stringify(pending);
  if (json === lastSent) return;
  lastSent = json;
  sendToR('config', { json });
}

export const rStorage: PersistStorage<unknown> = {
  getItem: () => saved,
  // Nothing is sent before the restore, so the defaults the page starts
  // with never replace what R kept
  setItem: (_name, value) => {
    if (!restored) return;
    pending = value;
    clearTimeout(timer);
    timer = setTimeout(flush, SAVE_DELAY);
  },
  removeItem: () => {},
};

// Ids of the pushed panels R holds, as of the restore (null before it)
export const heldPanels = (): Set<string> | null => held;

export function initPersist(): void {
  onMessage('restore', ({ config, panels }: { config: string | null; panels?: string[] }) => {
    // A reconnect without a reload: the page's own state is the newer one
    if (restored) return;
    restored = true;
    held = new Set(panels ?? []);
    let value: StorageValue<unknown> | null = null;
    try { value = config ? JSON.parse(config) : null; } catch (_) { /* start from defaults */ }
    resolve(value);
  });
}
