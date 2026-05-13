// WebSocket connects back to the same origin (same port as the HTTP server).
// This works in the RStudio viewer pane and any browser with no CORS issues.
// Reconnects every 2s until R's event loop processes the initial handshake.

let ws             = null;
let reconnectTimer = null;
const handlers     = new Map();
const outQueue     = [];

export const isConnected = () => ws?.readyState === WebSocket.OPEN;
export function onMessage(type, fn) { handlers.set(type, fn); }

export function sendToR(type, data) {
  const msg = JSON.stringify({ type, data });
  if (isConnected()) ws.send(msg);
  else outQueue.push(msg);
}

function setRStatus(s) {
  const el = document.getElementById('r-status');
  if (el) { el.className = s; el.title = 'R: ' + s; }
}

function connect() {
  ws = new WebSocket(`ws://${location.host}`);

  ws.onopen = () => {
    clearTimeout(reconnectTimer);
    setRStatus('connected');
    outQueue.splice(0).forEach(m => ws.send(m));
    console.log('GiottoLens: connected to R');
  };

  ws.onmessage = ({ data }) => {
    try {
      const msg = JSON.parse(data);
      handlers.get(msg.type)?.(msg.data);
    } catch (e) {
      console.warn('GiottoLens: bad message from R:', e);
    }
  };

  ws.onerror = () => setRStatus('disconnected');

  ws.onclose = () => {
    setRStatus('disconnected');
    reconnectTimer = setTimeout(connect, 2000);
  };
}

export function initComms() {
  connect();
}
