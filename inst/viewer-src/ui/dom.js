export function updateScalebar(viewState) {
  const pxPerMicron = Math.pow(2, viewState.zoom);
  const exp = Math.pow(10, Math.floor(Math.log10(100 / pxPerMicron)));
  const niceMicrons = [1, 2, 5, 10].map(x => x * exp).find(x => x * pxPerMicron >= 80) ?? exp * 10;
  const label = niceMicrons >= 1000 ? `${niceMicrons / 1000} mm` : `${niceMicrons} μm`;
  document.getElementById('scalebar-bar').style.width = (niceMicrons * pxPerMicron) + 'px';
  document.getElementById('scalebar-label').textContent = label;
}

// ── Canvas ↔ world coordinate transforms ─────────────────────────────────────
export function clientToWorld(clientX, clientY, canvas, viewState) {
  const rect  = canvas.getBoundingClientRect();
  const scale = Math.pow(2, viewState.zoom);
  const [cx, cy] = viewState.target;
  return [
    cx + (clientX - rect.left - rect.width  / 2) / scale,
    cy - (clientY - rect.top  - rect.height / 2) / scale,
  ];
}

// Panning that leaves the tool alone: a drag with the middle button, or with
// the left one while Space is held, pans `canvas`'s orthographic view
// (flipY false) whatever the tool. A ruler or polygon in progress carries on
// after it. Tools act on the left button only, and not while Space is held
// (spaceHeld()). The press is kept from deck.gl, so its own pan does not run
// as well. `get` and `set` read and apply the view state; `signal` removes
// the listeners.
let _space = false;
export const spaceHeld = () => _space;
export function setSpaceHeld(on) { _space = on; }

export function dragPan(canvas, get, set, { signal } = {}) {
  let last = null;
  window.addEventListener('pointerdown', e => {
    if (e.target !== canvas || !(e.button === 1 || (e.button === 0 && _space))) return;
    e.stopPropagation();
    if (e.button === 1) e.preventDefault();   // no autoscroll
    last = [e.clientX, e.clientY];
  }, { capture: true, signal });
  window.addEventListener('pointermove', e => {
    if (!last) return;
    if (!e.buttons) { last = null; return; }   // released outside the page
    const vs = get();
    if (!vs) return;
    const s = Math.pow(2, vs.zoom);
    const [tx, ty] = vs.target;
    set({ ...vs, target: [tx - (e.clientX - last[0]) / s, ty + (e.clientY - last[1]) / s, 0] });
    last = [e.clientX, e.clientY];
  }, { signal });
  window.addEventListener('pointerup', () => { last = null; }, { signal });
  window.addEventListener('blur', () => { last = null; }, { signal });
}

export function worldToClient(worldX, worldY, canvas, viewState) {
  const rect  = canvas.getBoundingClientRect();
  const scale = Math.pow(2, viewState.zoom);
  const [cx, cy] = viewState.target;
  return [
    rect.left + rect.width  / 2 + (worldX - cx) * scale,
    rect.top  + rect.height / 2 - (worldY - cy) * scale,
  ];
}

export function pointInPolygon(ring, x, y) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)
      inside = !inside;
  }
  return inside;
}

// ── Viewport ──────────────────────────────────────────────────────────────────
// Size of the spatial view in CSS pixels. The window is larger: the side
// panel and the stats column take part of it. Measured on the pane, since the
// canvas is still the default 300 × 150 until deck.gl sizes it. While an image
// is registered, its own pane takes the left half.
export function viewportSize() {
  const c = document.getElementById('spatial-pane');
  const width = c?.clientWidth || window.innerWidth;
  return { width: c?.classList.contains('registering') ? Math.floor(width / 2) : width,
           height: c?.clientHeight || window.innerHeight };
}

// A view state with `zoom` set. deck.gl's controller adds zoomX and zoomY,
// which take precedence over zoom; they are dropped so that zoom applies.
export function withZoom(vs, zoom) {
  const { zoomX: _x, zoomY: _y, ...rest } = vs;
  return { ...rest, zoom };
}

// Zoom that fits a w × h world box into a viewport of the given pixel size
export function fitZoom(w, h, { width, height } = viewportSize()) {
  return Math.log2(Math.min(width / Math.max(w, 1e-9), height / Math.max(h, 1e-9)));
}

// ── HTML ──────────────────────────────────────────────────────────────────────
// Escape data-derived text before it goes into innerHTML (gene names, IDs,
// metadata values and annotation names all come from user data).
const _ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export function escapeHtml(v) {
  return String(v).replace(/[&<>"']/g, c => _ESC[c]);
}
