// WebSocket connects back to the server that served this page (same port, so
// no CORS), at a URL relative to the page so path-prefixing proxies work.
// The page lives under /lens/<token>/, so the socket's URL carries the token R
// checks.
// Reconnects every 2s until R's event loop processes the initial handshake.
//
// Messages are { type, id?, data }. A message from R with an `id` is a
// request: the handler's return value (or error) goes back as
// { type: 'reply', id, data | error }. The page asks R in the other direction
// with askR(): { type: 'ask', id, data: { op, ... } }, answered with
// { type: 'answer', data: { id, data | error, code? } }.

// Bump when the message format changes; R warns on a mismatch
export const PROTOCOL = 7;

let ws             = null;
let reconnectTimer = null;
const handlers     = new Map();   // type → Set of handlers
const outQueue     = new Map();   // type → latest message while disconnected

let hello          = {};          // more for the 'ready' message (setHello())
let askSeq         = 0;
const asked        = new Map();   // ask id → { resolve, reject }
const connectFns   = new Set();   // called on every connect (onConnect())

export const isConnected = () => ws?.readyState === WebSocket.OPEN;

// What the page tells R on every connect besides its protocol: the load its
// manifest came from, so R can make a page from before a set_object() reload
export function setHello(data) { hello = { ...data }; }

// `fn` runs on every connect, after 'ready' is sent; returns an unsubscribe
export function onConnect(fn) {
  connectFns.add(fn);
  return () => connectFns.delete(fn);
}

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

// Ask R (op and its arguments); resolves with R's answer, or rejects with an
// Error carrying R's message and `code`. Only while connected: an ask is an
// action, not state, so it is never queued.
export function askR(op, args = {}) {
  if (!isConnected()) return Promise.reject(new Error('R is not connected'));
  const id = `ask-${++askSeq}`;
  return new Promise((resolve, reject) => {
    asked.set(id, { resolve, reject });
    ws.send(JSON.stringify({ type: 'ask', id, data: { op, ...args } }));
  });
}

function onAnswer({ id, data, error, code }) {
  const p = asked.get(id);
  if (!p) return;
  asked.delete(id);
  if (error != null) p.reject(Object.assign(new Error(error), { code }));
  else p.resolve(data);
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
    ws.send(JSON.stringify({ type: 'ready', data: { ...hello, protocol: PROTOCOL } }));
    for (const m of outQueue.values()) ws.send(m);
    outQueue.clear();
    for (const fn of connectFns) fn();
  };

  ws.onmessage = ({ data }) => {
    let msg;
    try { msg = JSON.parse(data); } catch (e) { reportError(e, 'parsing a message from R'); return; }
    if (msg.type === 'answer') onAnswer(msg.data ?? {});
    else dispatch(msg);
  };

  ws.onerror = () => setRStatus('disconnected');

  ws.onclose = () => {
    setRStatus('disconnected');
    // Their answers would come on this socket
    for (const p of asked.values()) p.reject(new Error('R disconnected'));
    asked.clear();
    reconnectTimer = setTimeout(connect, 2000);
  };
}

// Call after every onMessage() handler is registered
let _started = false;
export function initComms() {
  if (_started) return;
  _started = true;
  window.addEventListener('error', e => reportError(e.error ?? e.message, 'uncaught'));
  // A request aborted on purpose (a tile that left the view, an image hidden
  // while loading) is not an error, also where a library leaves it unawaited
  window.addEventListener('unhandledrejection', e => {
    if (e.reason?.name === 'AbortError') { e.preventDefault(); return; }
    reportError(e.reason, 'unhandled rejection');
  });
  connect();
}
