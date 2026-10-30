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
