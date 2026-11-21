// WebSocket connects back to the server that served this page (same port, so
// no CORS), at a URL relative to the page so path-prefixing proxies work.
// The page lives under /lens/<token>/, so the socket's URL carries the token R
// checks.
// Reconnects every 2s until R's event loop processes the initial handshake.
//
// One window shows the viewer (adr/0028). On every connect the page says
// 'hello' with the key of its last grant and, in the window launch_lens()
// opened by a command, the key from the URL's fragment. R answers 'grant'
// (the data secret and a key): the page then sends 'ready' and is live. Or
// it answers 'wait' (a code): the page shows the code until it is given to
// R, in the console or typed in the window that shows the viewer. 'released'
// says the viewer moved to another window. 'probe' asks the window that shows the viewer whether it
// is there, when its key comes from another connection: it replies.
// ui/gate.ts shows these states.
//
// Messages are { type, id?, data }. A message from R with an `id` is a
// request: the handler's return value (or error) goes back as
// { type: 'reply', id, data | error }. The page asks R in the other direction
// with askR(): { type: 'ask', id, data: { op, ... } }, answered with
// { type: 'answer', data: { id, data | error, code? } }.

import { dataRoot, setDataRoot } from './base.ts';

// Bump when the message format changes; R warns on a mismatch
export const PROTOCOL = 9;

let ws             = null;
let reconnectTimer = null;
let stopped        = false;   // R said the viewer is closing: no reconnect
let granted        = false;   // R gave this window the viewer on this socket
let live           = false;   // and 'ready' was sent on it
let registered     = false;   // initComms() ran: every handler is registered
let quiet          = false;   // the viewer moved to another window: no 'hello' until asked
const handlers     = new Map();   // type → Set of handlers
const outQueue     = new Map();   // type → latest message while disconnected

let hello          = {};          // more for the 'ready' message (setHello())
let askSeq         = 0;
const asked        = new Map();   // ask id → { resolve, reject }
const connectFns   = new Set();   // called on every connect (onConnect())

export const isConnected = () => ws?.readyState === WebSocket.OPEN && live;

// The key of this window's last grant, kept for a reload. Per page path: a
// proxy may serve several viewers from one origin.
const KEY = `giottolens-window:${globalThis.location?.pathname ?? ''}`;
const windowKey = () => { try { return sessionStorage.getItem(KEY); } catch { return null; } };

// Whether this window shows the viewer: { state: 'connecting' | 'granted' |
// 'waiting' | 'reconnecting' | 'released' | 'closed', code? }. 'reconnecting':
// a window that waited lost its socket, and shows no code until R sends one
// again. `fn` gets the current one at once and each change; the returned
// function unsubscribes.
let gate = { state: 'connecting' };
const gateFns = new Set();
export function onGate(fn) {
  gateFns.add(fn);
  fn(gate);
  return () => gateFns.delete(fn);
}
function setGate(g) {
  gate = g;
  gateFns.forEach(fn => fn(g));
}

// The key launch_lens() puts in the fragment of the URL it opens, for one
// window (adr/0028). Taken out of the address bar, so it is not copied with
// the URL or kept in the history.
function takeLaunchKey() {
  const m = /^#launch=([A-Za-z0-9]+)$/.exec(globalThis.location?.hash ?? '');
  if (!m) return null;
  try { history.replaceState(history.state, '', location.pathname + location.search); } catch { /* stays */ }
  return m[1];
}
let launchKey = takeLaunchKey();

function sayHello() {
  ws.send(JSON.stringify({ type: 'hello', data: {
    protocol: PROTOCOL, key: windowKey(), ...(launchKey ? { launch: launchKey } : {}),
  } }));
}

// Ask R for the viewer again, from a window it was moved away from
export function requestViewer() {
  quiet = false;
  if (ws?.readyState === WebSocket.OPEN) sayHello();
}

let resolveGrant;
const firstGrant = new Promise(r => { resolveGrant = r; });

// Connect and wait until R gives this window the viewer: the data cannot be
// read before. Call before the first dataUrl() fetch.
export function acquire() {
  if (!ws) connect();
  return firstGrant;
}

function onGrant({ data, key }) {
  launchKey = null;
  try { sessionStorage.setItem(KEY, key); } catch { /* a reload asks again */ }
  // The page's URLs are those of an earlier grant: start over with this one
  if (dataRoot() && dataRoot() !== `d/${data}/`) { location.reload(); return; }
  setDataRoot(data);
  granted = true;
  setGate({ state: 'granted' });
  resolveGrant();
  if (registered && !live) announce();
}

// Handlers are registered, so R may send right away
function announce() {
  ws.send(JSON.stringify({ type: 'ready', data: { ...hello, protocol: PROTOCOL } }));
  live = true;
  setRStatus('connected');
  for (const m of outQueue.values()) ws.send(m);
  outQueue.clear();
  for (const fn of connectFns) fn();
}

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

// Their answers come on this socket, to the window that shows the viewer
function dropAsks(why) {
  for (const p of asked.values()) p.reject(new Error(why));
  asked.clear();
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

// The connection to R ('connecting', 'connected' once this window shows the
// viewer and said 'ready', 'disconnected', or 'closed' once R has stopped
// the viewer), shown in the selection bar
// (ui/selbar.js). `fn` gets the current one at once and each
// change; the returned function unsubscribes.
let rStatus = 'connecting';
const statusFns = new Set();
export function onRStatus(fn) {
  statusFns.add(fn);
  fn(rStatus);
  return () => statusFns.delete(fn);
}
function setRStatus(s) {
  rStatus = s;
  statusFns.forEach(fn => fn(s));
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
    if (!quiet) sayHello();
  };

  ws.onmessage = ({ data }) => {
    let msg;
    try { msg = JSON.parse(data); } catch (e) { reportError(e, 'parsing a message from R'); return; }
    if (msg.type === 'grant') onGrant(msg.data ?? {});
    else if (msg.type === 'wait') setGate({ state: 'waiting', code: msg.data?.code });
    else if (msg.type === 'released') {
      granted = live = false;
      quiet = true;
      setRStatus('disconnected');
      dropAsks('the viewer moved to another window');
      setGate({ state: 'released' });
    }
    // viewer$close(): the server is going away, so stop trying to reach it
    else if (msg.type === 'closed') { stopped = true; setGate({ state: 'closed' }); }
    else if (!granted) return;
    else if (msg.type === 'probe') ws.send(JSON.stringify({ type: 'reply', id: msg.id, data: {} }));
    else if (msg.type === 'answer') onAnswer(msg.data ?? {});
    else dispatch(msg);
  };

  ws.onerror = () => setRStatus('disconnected');

  ws.onclose = () => {
    granted = live = false;
    setRStatus(stopped ? 'closed' : 'disconnected');
    dropAsks('R disconnected');
    if (gate.state === 'waiting') setGate({ state: 'reconnecting' });
    if (!stopped) reconnectTimer = setTimeout(connect, 2000);
  };
}

// Call after every onMessage() handler is registered
let _started = false;
export function initComms() {
  if (_started) return;
  _started = true;
  registered = true;
  window.addEventListener('error', e => reportError(e.error ?? e.message, 'uncaught'));
  // A request aborted on purpose (a tile that left the view, an image hidden
  // while loading) is not an error, also where a library leaves it unawaited
  window.addEventListener('unhandledrejection', e => {
    if (e.reason?.name === 'AbortError') { e.preventDefault(); return; }
    reportError(e.reason, 'unhandled rejection');
  });
  if (!ws) connect();
  // In a task of its own, as a socket's open is: what asked R during this one
  // has heard its refusal by then, and asks again on connect
  else setTimeout(() => { if (granted && !live && ws?.readyState === WebSocket.OPEN) announce(); }, 0);
}
