// WebSocket connects back to the server that served this page (same port, so
// no CORS), at a URL relative to the page so path-prefixing proxies work.
// The page lives under /lens/<token>/, so the socket's URL carries the token R
// checks.
// Reconnects every 2s until R's event loop processes the initial handshake.
//
// Messages are { type, id?, data }. A message from R with an `id` is a
// request: the handler's return value (or error) goes back as
// { type: 'reply', id, data | error }.

// Bump when the message format changes; R warns on a mismatch
export const PROTOCOL = 2;

let ws             = null;
let reconnectTimer = null;
const handlers     = new Map();   // type → Set of handlers
const outQueue     = new Map();   // type → latest message while disconnected

export const isConnected = () => ws?.readyState === WebSocket.OPEN;

export function onMessage(type, fn) {
  if (!handlers.has(type)) handlers.set(type, new Set());
  handlers.get(type).add(fn);
  return () => handlers.get(type)?.delete(fn);
}

// While disconnected only the latest message of each type is kept: they all
// carry full state (selection, annotations), not deltas.
export function sendToR(type, data) {
  const msg = JSON.stringify({ type, data });
  if (isConnected()) ws.send(msg);
  else outQueue.set(type, msg);
}

export function reportError(err, where = '') {
  console.error('GiottoLens', where, err);
  sendToR('client_error', {
    where, message: String(err?.message ?? err), stack: String(err?.stack ?? ''),
  });
}

function setRStatus(s) {
  const el = document.getElementById('r-status');
  if (el) { el.className = s; el.title = 'R: ' + s; }
}

function wsUrl() {
  const u = new URL('ws', document.baseURI);
  u.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return u.href;
}

async function dispatch(msg) {
  const fns = handlers.get(msg.type);
  const reply = (data, error) => {
    if (msg.id != null) ws?.send(JSON.stringify({ type: 'reply', id: msg.id, data, error }));
  };
  if (!fns?.size) { reply(null, `unknown message type '${msg.type}'`); return; }
  let result;
  try {
    for (const fn of fns) {
      const r = await fn(msg.data ?? {});
      if (r !== undefined) result = r;
    }
  } catch (e) {
    // A request's error goes back to R in the reply; anything else is reported
    if (msg.id != null) { console.warn('GiottoLens', msg.type, e); reply(null, String(e?.message ?? e)); }
    else reportError(e, `handling '${msg.type}'`);
    return;
  }
  reply(result ?? null);
}

function connect() {
  ws = new WebSocket(wsUrl());

  ws.onopen = () => {
    clearTimeout(reconnectTimer);
    setRStatus('connected');
    // Handlers are registered before connect(), so R may send right away
    ws.send(JSON.stringify({ type: 'ready', data: { protocol: PROTOCOL } }));
    for (const m of outQueue.values()) ws.send(m);
    outQueue.clear();
  };

  ws.onmessage = ({ data }) => {
    let msg;
    try { msg = JSON.parse(data); } catch (e) { reportError(e, 'parsing a message from R'); return; }
    dispatch(msg);
  };

  ws.onerror = () => setRStatus('disconnected');

  ws.onclose = () => {
    setRStatus('disconnected');
    reconnectTimer = setTimeout(connect, 2000);
  };
}

// Call after every onMessage() handler is registered
let _started = false;
export function initComms() {
  if (_started) return;
  _started = true;
  window.addEventListener('error', e => reportError(e.error ?? e.message, 'uncaught'));
  window.addEventListener('unhandledrejection', e => reportError(e.reason, 'unhandled rejection'));
  connect();
}
