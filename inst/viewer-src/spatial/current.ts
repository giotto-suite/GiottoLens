// The spatial view on the page, if one is open. It is a dock panel
// (spatial/view.ts) that can be closed, so code that draws, moves the camera
// or reads the view asks here and does nothing when there is none. One view
// for now; several (spaces, gmulti samples) will each be one of these
// (adr/0023).

export interface SpatialView {
  root: HTMLElement;              // .spatial-pane: the panel's content
  canvas: HTMLCanvasElement;
  deck: any;
  viewState: any;                 // null until the pane has a size
  initialViewState: any;          // fitted to the data (zoom to fit)
  signal: AbortSignal;            // aborted when the view closes; its listeners go with it
  el: Record<string, HTMLElement>; // its overlays by role ([data-el] in the template)
  regDeck: any;                   // the registered image's pane (ui/registration.ts)
}

let _view: SpatialView | null = null;
export const spatialView = (): SpatialView | null => _view;
export function setSpatialView(v: SpatialView | null): void { _view = v; }

// For R commands that need a view (set_view, screenshot)
export function needView(): SpatialView {
  if (!_view?.viewState) throw new Error('no spatial view is open; add one from a + menu');
  return _view;
}
