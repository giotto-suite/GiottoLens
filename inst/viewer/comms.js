// WebSocket connection to R via httpuv.
// Port is passed in the URL: ?ws_port=PORT
// Fails gracefully when not present — viewer works standalone.

const params  = new URLSearchParams(window.location.search);
const wsPort  = params.get('ws_port');

let ws       = null;
const handlers  = new Map();
const outQueue  = [];

export const isConnected = () => ws?.readyState === WebSocket.OPEN;

// Register a handler for messages arriving from R
export function onMessage(type, fn) { handlers.set(type, fn); }

// Send a message to R
export function sendToR(type, data) {
  const msg = JSON.stringify({ type, data });
  if (isConnected()) ws.send(msg);
  else outQueue.push(msg); // queued until connection opens
}

export function initComms() {
  if (!wsPort) {
    console.log('GiottoAtlas: no ws_port param — running standalone (no R connection)');
    return;
  }

  ws = new WebSocket(`ws://localhost:${wsPort}`);

  ws.onopen = () => {
    console.log(`GiottoAtlas: connected to R on port ${wsPort}`);
    outQueue.splice(0).forEach(m => ws.send(m)); // flush queued messages
  };

  ws.onmessage = ({ data }) => {
    try {
      const msg = JSON.parse(data);
      handlers.get(msg.type)?.(msg.data);
    } catch (e) {
      console.warn('GiottoAtlas: invalid message from R:', e);
    }
  };

  ws.onerror = () => console.warn('GiottoAtlas: R WebSocket error');
  ws.onclose = () => console.log('GiottoAtlas: R connection closed');
}
