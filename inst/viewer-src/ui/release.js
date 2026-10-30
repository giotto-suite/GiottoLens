// A button released outside the page never reaches it: e.g. outside the
// Positron / RStudio viewer pane, which shows the viewer in an embedded frame.
// deck.gl's input handling then still thinks the button is down, and the next
// move keeps panning ("sticky" pans); our lasso and brush stay active too.
// When a move arrives with no button down during a drag, or the page loses
// focus, send the release that was missed.
let _drag = null;   // { pointerId, pointerType } of the drag in progress

function release(x, y) {
  if (!_drag) return;
  const { pointerId, pointerType } = _drag;
  _drag = null;
  const init = { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons: 0 };
  window.dispatchEvent(new PointerEvent('pointerup', { ...init, pointerId, pointerType }));
  window.dispatchEvent(new MouseEvent('mouseup', init));
}

export function initReleaseGuard() {
  window.addEventListener('pointerdown', e => {
    if (e.button === 0) _drag = { pointerId: e.pointerId, pointerType: e.pointerType };
  }, { capture: true });
  window.addEventListener('pointerup', e => { if (e.isTrusted) _drag = null; }, { capture: true });
  window.addEventListener('pointermove', e => {
    if (_drag && e.pointerType === 'mouse' && e.buttons === 0) release(e.clientX, e.clientY);
  }, { capture: true });
  window.addEventListener('blur', () => release(0, 0));
}
