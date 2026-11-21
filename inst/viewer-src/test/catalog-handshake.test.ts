// Catalog loading across the window handshake (data/catalog.ts, core/comms.js):
// an ask refused before the page is live is asked again on connect, also when
// the panel was built in the same task as initComms()
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
const tick = () => new Promise(r => setTimeout(r, 0));
const payload = { spat_unit: 'bin', sources: [{ id: 1, slot: 'cell_metadata', feat_type: 'rna', items: ['a', 'b'] }] };

describe('catalog across the handshake', () => {
  let comms: any, catalog: any;
  beforeEach(async () => {
    vi.resetModules();
    vi.stubGlobal('WebSocket', FakeSocket);
    vi.stubGlobal('document', { baseURI: 'http://lens/lens/tok/' });
    vi.stubGlobal('location', { protocol: 'http:', pathname: '/lens/tok/', reload: () => {} });
    vi.stubGlobal('window', { addEventListener: () => {} });
    vi.stubGlobal('sessionStorage', { getItem: () => null, setItem: () => {} });
    comms = await import('../core/comms.js');
    catalog = await import('../data/catalog.ts');
  });

  it('a panel built before the page is live gets the catalog on connect', async () => {
    const got: any[] = [];
    // A panel as panels/data.ts: load at once, and again on connect
    let sources: any[] = [];
    let note = '';
    const load = async () => {
      if (sources.length) return;
      try { sources = await catalog.loadCatalog(); got.push(sources); } catch (e: any) { note = e.message; }
    };
    const granted = comms.acquire();
    const ws = FakeSocket.last;
    ws.open();
    ws.say('grant', { data: 'S', key: 'K' });
    await granted;
    void load();                              // built during boot: granted, not live
    comms.onConnect(() => void load());
    await tick();
    expect(note).toBe('R is not connected');
    comms.initComms();                        // 'ready', then the connect callbacks
    await tick();
    const asks = ws.sent.filter(m => m.type === 'ask');
    expect(ws.types().slice(0, 2)).toEqual(['hello', 'ready']);
    expect(asks.map(m => m.data.op)).toEqual(['catalog']);
    ws.say('answer', { id: asks[0].id, data: payload });
    await tick();
    expect(got.length).toBe(1);
    expect(sources[0].items).toEqual(['a', 'b']);
  });

  it('a panel built in the same task as the connect is not left without it', async () => {
    let sources: any[] = [];
    let note = '';
    const load = async () => {
      if (sources.length) return;
      try { sources = await catalog.loadCatalog(); } catch (e: any) { note = e.message; }
    };
    const granted = comms.acquire();
    const ws = FakeSocket.last;
    ws.open();
    ws.say('grant', { data: 'S', key: 'K' });
    await granted;
    void load();                              // no task boundary before initComms()
    comms.onConnect(() => void load());
    comms.initComms();
    await tick();
    const asks = ws.sent.filter(m => m.type === 'ask');
    expect(asks.map(m => m.data.op)).toEqual(['catalog']);
    ws.say('answer', { id: asks[0].id, data: payload });
    await tick();
    expect(note).toBe('R is not connected');   // the first, refused ask
    expect(sources.length).toBe(1);
  });
});
