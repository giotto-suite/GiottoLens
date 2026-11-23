// Modules (adr/0031): modes for one task, entered and left from the tools
// rail's modules button (panels/tools.ts) or by R (viewer$set_module()). While
// one is on, the tray offers its controls only (panels/tray.ts) and the data
// area shows its view alone, that view's pane maximized (panels/dock.ts
// focusView()); leaving puts back the tray's controls and the panes as they
// were. Which module is on is saved with the config (store `module`), and the
// tray keeps the controls shown per module (`trayShown`).
//
// A module is one entry in MODULES: the controls it offers, the view it
// shows, whether this launch can use it, and what entering and leaving do.
import { state } from '../core/state.js';
import { store, actions } from '../core/store.ts';
import type { ControlKind } from './tray.ts';
import { placeControls, showTray } from './tray.ts';
import { focusView } from './dock.ts';

interface Module {
  label: string;
  icon: string;               // lucide's name
  controls: ControlKind[];    // what the tray offers while it is on, all shown at first
  view: 'spatial';            // the view the data area shows alone
  available(): boolean;
  needs: string;              // what it waits for while not available
  enter?(): void;
  exit?(): void;
}

export const MODULES = {
  // Images registered by landmarks: the spatial view splits into the image's
  // pane and the data's while placing points (ui/registration.ts)
  registration: {
    label: 'registration', icon: 'crosshair', controls: ['register'], view: 'spatial',
    available: () => !!state.images?.size,
    needs: 'an image: add one in the layers panel',
    enter: () => { if (store.getState().registration) actions.setMode('landmark'); },
    exit: () => { if (store.getState().mode === 'landmark') actions.setMode('pan'); },
  },
} satisfies Record<string, Module>;
export type ModuleId = keyof typeof MODULES;
const moduleOf = (id: string | null | undefined): Module | undefined =>
  id ? (MODULES as Record<string, Module>)[id] : undefined;
export const isModule = (id: string): id is ModuleId => !!moduleOf(id);

// The module on: the store's, while this launch can use it
export function activeModule(): ModuleId | null {
  const id = store.getState().module;
  return id && isModule(id) && moduleOf(id)!.available() ? id : null;
}
export const moduleControls = (id: ModuleId): ControlKind[] => moduleOf(id)!.controls;
// Controls only a module offers: not on the tray's rail without it
export const moduleOnly = (kind: ControlKind): boolean =>
  Object.values(MODULES as Record<string, Module>).some(m => m.controls.includes(kind));
// The view the data area shows alone, while a module is on
export const moduleView = (): string | null => moduleOf(activeModule())?.view ?? null;

// For the modules menu
export function moduleList(): { id: ModuleId; label: string; icon: string; on: boolean; available: boolean; needs: string }[] {
  const on = activeModule();
  return (Object.keys(MODULES) as ModuleId[]).map(id => {
    const m = moduleOf(id)!;
    return { id, label: m.label, icon: m.icon, on: id === on, available: m.available(), needs: m.needs };
  });
}

// Enter a module (another one on is left), or leave the one on with null
export function setModule(id: ModuleId | null): void {
  if (id && !moduleOf(id)!.available()) throw new Error(`the ${moduleOf(id)!.label} module needs ${moduleOf(id)!.needs}`);
  actions.setModule(id);
}

// The tray and the data area as the module on asks; also once what a module
// needs arrives (images open after the restore)
let applied: ModuleId | null = null;
export function applyModule(): void {
  const on = activeModule();
  if (on !== applied) {
    moduleOf(applied)?.exit?.();
    applied = on;
    if (on) showTray();
    moduleOf(on)?.enter?.();
  }
  placeControls();
  focusView(moduleView());
}

export function initModules(): void {
  store.subscribe(s => s.module, applyModule);
  // A registration started from R (register_image()) or the register panel
  // enters its module
  store.subscribe(s => s.mode, mode => {
    if (mode === 'landmark' && store.getState().registration && store.getState().module !== 'registration'
        && MODULES.registration.available())
      actions.setModule('registration');
  });
}
