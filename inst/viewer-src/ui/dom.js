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
// canvas is still the default 300 × 150 until deck.gl sizes it.
export function viewportSize() {
  const c = document.getElementById('spatial-pane');
  return { width: c?.clientWidth || window.innerWidth, height: c?.clientHeight || window.innerHeight };
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
