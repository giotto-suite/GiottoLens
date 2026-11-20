// The window handshake of core/comms.js (adr/0028), against a fake socket
import { beforeEach, describe, expect, it, vi } from 'vitest';

class FakeSocket {
  static OPEN = 1;
  static last: FakeSocket;
  readyState = 0;
  sent: any[] = [];
  onopen?: () => void;
  onmessage?: (e: { data: string }) => void;
  onclose?: () => void;
  onerror?: () => void;
  constructor(public url: string) { FakeSocket.last = this; }
  send(m: string) { this.sent.push(JSON.parse(m)); }
  open() { this.readyState = 1; this.onopen?.(); }
  say(type: string, data?: unknown) { this.onmessage?.({ data: JSON.stringify({ type, data }) }); }
  types() { return this.sent.map(m => m.type); }
}

const store = new Map<string, string>();
const reload = vi.fn();

async function load() {
  vi.resetModules();
  store.clear();
  reload.mockClear();
  vi.stubGlobal('WebSocket', FakeSocket);
  vi.stubGlobal('document', { baseURI: 'http://lens/lens/tok/' });
  vi.stubGlobal('location', { protocol: 'http:', pathname: '/lens/tok/', reload });
  vi.stubGlobal('window', { addEventListener: () => {} });
  vi.stubGlobal('sessionStorage', {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => { store.set(k, v); },
  });
  const comms = await import('../core/comms.js');
  const base = await import('../core/base.ts');
  return { comms, base };
}

describe('window handshake', () => {
  let comms: any, base: any, gates: any[];
  beforeEach(async () => {
    ({ comms, base } = await load());
    gates = [];
    comms.onGate((g: any) => gates.push(g));
  });

  it('says hello, waits with the code, and reads data only after the grant', async () => {
    let got = false;
    comms.acquire().then(() => { got = true; });
    const ws = FakeSocket.last;
    expect(ws.url).toBe('ws://lens/lens/tok/ws');
    ws.open();
    expect(ws.sent).toEqual([{ type: 'hello', data: { protocol: comms.PROTOCOL, key: null } }]);
    ws.say('wait', { code: '4821' });
    await Promise.resolve();
    expect(gates.at(-1)).toEqual({ state: 'waiting', code: '4821' });
    expect(got).toBe(false);
    expect(comms.isConnected()).toBe(false);

    ws.say('grant', { data: 'SECRET', key: 'KEY' });
    await Promise.resolve();
    expect(got).toBe(true);
    expect(gates.at(-1)).toEqual({ state: 'granted' });
    expect(base.dataUrl('session/manifest.json')).toBe('http://lens/lens/tok/d/SECRET/session/manifest.json');
    expect([...store.values()]).toEqual(['KEY']);
    // 'ready' goes once the handlers are registered
    expect(ws.types()).toEqual(['hello']);
    comms.initComms();
    expect(ws.types()).toEqual(['hello', 'ready']);
    expect(comms.isConnected()).toBe(true);
  });

  it('queues messages until it is live and ignores R before the grant', async () => {
    const seen: any[] = [];
    comms.onMessage('ping', (d: any) => { seen.push(d); });
    comms.initComms();
    const ws = FakeSocket.last;
    ws.open();
    comms.sendToR('config', { json: '{}' });
    ws.say('ping', { n: 1 });
    await Promise.resolve();
    expect(seen).toEqual([]);
    expect(ws.types()).toEqual(['hello']);
    ws.say('grant', { data: 'S', key: 'K' });
    expect(ws.types()).toEqual(['hello', 'ready', 'config']);
    ws.say('ping', { n: 2 });
    await Promise.resolve();
    expect(seen).toEqual([{ n: 2 }]);
  });

  it('a reconnect sends the key; a grant of other data paths reloads the page', () => {
    comms.initComms();
    const a = FakeSocket.last;
    a.open();
    a.say('grant', { data: 'S1', key: 'K1' });
    a.readyState = 3;
    vi.useFakeTimers();
    a.onclose?.();
    expect(comms.isConnected()).toBe(false);
    vi.advanceTimersByTime(2000);
    vi.useRealTimers();
    const b = FakeSocket.last;
    expect(b).not.toBe(a);
    b.open();
    expect(b.sent[0]).toEqual({ type: 'hello', data: { protocol: comms.PROTOCOL, key: 'K1' } });
    b.say('grant', { data: 'S1', key: 'K1' });
    expect(reload).not.toHaveBeenCalled();
    expect(b.types()).toEqual(['hello', 'ready']);
    b.say('grant', { data: 'S2', key: 'K2' });
    expect(reload).toHaveBeenCalledTimes(1);
  });

  it('released: not live, quiet on reconnect until the viewer is asked for', () => {
    comms.initComms();
    const a = FakeSocket.last;
    a.open();
    a.say('grant', { data: 'S1', key: 'K1' });
    a.say('released');
    expect(gates.at(-1)).toEqual({ state: 'released' });
    expect(comms.isConnected()).toBe(false);
    comms.sendToR('close', null);
    expect(a.types()).toEqual(['hello', 'ready']);
    a.readyState = 3;
    vi.useFakeTimers();
    a.onclose?.();
    vi.advanceTimersByTime(2000);
    vi.useRealTimers();
    const b = FakeSocket.last;
    b.open();
    expect(b.sent).toEqual([]);
    comms.requestViewer();
    expect(b.types()).toEqual(['hello']);
  });

  it('closed: says so and does not reconnect', () => {
    comms.initComms();
    const a = FakeSocket.last;
    a.open();
    a.say('closed');
    expect(gates.at(-1)).toEqual({ state: 'closed' });
    a.readyState = 3;
    vi.useFakeTimers();
    a.onclose?.();
    vi.advanceTimersByTime(5000);
    vi.useRealTimers();
    expect(FakeSocket.last).toBe(a);
  });
});
