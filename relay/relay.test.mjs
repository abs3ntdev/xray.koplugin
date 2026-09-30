import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHmac, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import vm from 'node:vm';
import { createRelay, LIMITS, validateOrigin } from './app.mjs';
import { createServer } from './server.mjs';
import { HTML_PAGE } from '../cloudflare-worker/worker.js';

const origin = 'https://relay.example.test';
const encrypted = 'HMAC:' + Buffer.alloc(64, 7).toString('base64');
const request = (path, method = 'GET', body, headers = {}) => new Request(origin + path, {
  method, headers: { 'Content-Type': 'application/json', ...headers },
  ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }),
});
const create = async app => (await app.fetch(request('/api/session/create', 'POST', {}))).json();

test('strict public HTTPS root origins', () => {
  assert.equal(validateOrigin('https://Relay.Example.Test/'), origin);
  for (const input of [undefined, null, '', 'http://relay.example.test', 'https://localhost',
    'https://127.0.0.1', 'https://[::1]', 'https://user@relay.example.test', 'https://relay.example.test:443',
    'https://relay.example.test/path', origin + '?q=x', origin + '#secret', origin + '/?q=x',
    'https://relay.example.test\\evil', origin + '\n', 'https://-bad.example', 'https://bad-.example',
    'https://bad..example', 'https://bad.example.', 'https://' + 'x'.repeat(64) + '.example']) {
    assert.throws(() => validateOrigin(input), /RELAY_ORIGIN/);
  }
});

test('create, pending, submit and repeat poll preserve existing wire contract', async () => {
  const app = createRelay({ origin });
  const { session_id: id, expires_in, success } = await create(app);
  assert.match(id, /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/);
  assert.equal(success, true); assert.equal(expires_in, 600);
  const path = `/api/session/${id.toLowerCase()}`;
  assert.equal((await app.fetch(request(path + '/poll'))).status, 204);
  assert.equal((await app.fetch(request(path + '/submit', 'POST', { encrypted_payload: encrypted }))).status, 200);
  for (let i = 0; i < 2; i++) {
    const res = await app.fetch(request(path + '/poll'));
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await res.json(), { success: true, status: 'ready', payload: encrypted });
  }
  // Identical retry works; a second different result cannot replace the first.
  assert.equal((await app.fetch(request(path + '/submit', 'POST', { encrypted_payload: encrypted }))).status, 200);
  assert.equal((await app.fetch(request(path + '/submit', 'POST', { encrypted_payload: 'HMAC:' + Buffer.alloc(64, 8).toString('base64') }))).status, 409);
});

test('both pending and submitted sessions expire exactly at TTL; restarting loses state', async () => {
  let time = 0;
  const app = createRelay({ origin, now: () => time });
  const pending = await create(app), ready = await create(app);
  await app.fetch(request(`/api/session/${ready.session_id}/submit`, 'POST', { encrypted_payload: encrypted }));
  time = LIMITS.ttlSeconds * 1000;
  for (const id of [pending.session_id, ready.session_id]) {
    assert.equal((await app.fetch(request(`/api/session/${id}/poll`))).status, 404);
    assert.equal((await app.fetch(request(`/api/session/${id}/submit`, 'POST', { encrypted_payload: encrypted }))).status, 404);
  }
  const restarted = createRelay({ origin });
  assert.equal((await restarted.fetch(request(`/api/session/${ready.session_id}/poll`))).status, 404);
});

test('collision never overwrites an existing session', async () => {
  const app = createRelay({ origin, generateId: () => 'ABC234' });
  await create(app);
  assert.equal((await app.fetch(request('/api/session/create', 'POST', {}))).status, 503);
  assert.equal((await app.fetch(request('/api/session/ABC234/poll'))).status, 204);
});

test('bounded create rate, request rate and session capacity recover', async () => {
  let time = 0, next = 0;
  const app = createRelay({ origin, now: () => time, generateId: () => (++next).toString(36).toUpperCase().padStart(6, 'A') });
  for (let i = 0; i < LIMITS.maxSessions; i++) {
    if (i && i % LIMITS.createsPerMinute === 0) time += 60000;
    assert.equal((await app.fetch(request('/api/session/create', 'POST', {}))).status, 200);
  }
  assert.equal((await app.fetch(request('/api/session/create', 'POST', {}))).status, 503);
  time += LIMITS.ttlSeconds * 1000;
  assert.equal((await app.fetch(request('/api/session/create', 'POST', {}))).status, 200);
  const limited = createRelay({ origin, now: () => 0 });
  for (let i = 0; i < LIMITS.createsPerMinute; i++) await create(limited);
  assert.equal((await limited.fetch(request('/api/session/create', 'POST', {}))).status, 429);
  const requests = createRelay({ origin, now: () => 0 });
  for (let i = 0; i < LIMITS.requestsPerMinute; i++) await requests.fetch(request('/'));
  const res = await requests.fetch(request('/'));
  assert.equal(res.status, 429); assert.equal(res.headers.get('retry-after'), '60');
});

test('malformed, plaintext, oversized and noncanonical payloads are rejected', async () => {
  const app = createRelay({ origin });
  const { session_id: id } = await create(app);
  for (const body of ['{', 'null', '[]', '{}', { encrypted_payload: 42 },
    { encrypted_payload: { api_key: 'dummy-only' } }, { encrypted_payload: 'dummy-only' },
    { encrypted_payload: 'HMAC:' + Buffer.alloc(32).toString('base64') },
    { encrypted_payload: encrypted + '\n' }, { encrypted_payload: 'HMAC:' + 'A'.repeat(10000) },
    { encrypted_payload: encrypted.slice(0, -3) + 'B==' }]) {
    assert.equal((await app.fetch(request(`/api/session/${id}/submit`, 'POST', body))).status, 400);
  }
  assert.equal((await app.fetch(request(`/api/session/${id}/submit`, 'POST', 'x'.repeat(LIMITS.maxBodyBytes + 1)))).status, 413);
  assert.equal((await app.fetch(request(`/api/session/${id}/submit`, 'POST', '{}', { 'Content-Type': 'text/plain' }))).status, 415);
});

test('cross-origin requests and credential headers fail closed; no redirects', async () => {
  const app = createRelay({ origin });
  for (const headers of [{ Origin: 'https://evil.example' }, { Origin: 'null' }]) {
    assert.equal((await app.fetch(request('/api/session/create', 'POST', {}, headers))).status, 403);
  }
  for (const header of ['Authorization', 'Cookie', 'Proxy-Authorization', 'X-Api-Key']) {
    assert.equal((await app.fetch(request('/api/session/create', 'POST', {}, { [header]: 'dummy-only' }))).status, 400);
  }
  assert.equal((await app.fetch(new Request('https://other.example/'))).status, 400);
  const cors = await app.fetch(request('/api/session/create', 'OPTIONS', undefined, { Origin: origin }));
  assert.equal(cors.status, 204); assert.equal(cors.headers.get('access-control-allow-origin'), origin);
  assert.equal((await app.fetch(request('/https://evil.example'))).status, 404);
});

test('public page and health GETs ignore incidental cookies without accepting authorization', async () => {
  const app = createRelay({ origin });
  const cookie = 'parent_session=dummy-cookie-only';
  for (const path of ['/', '/?s=ABC234', '/index.html', '/healthz']) {
    const res = await app.fetch(request(path, 'GET', undefined, { Cookie: cookie }));
    assert.equal(res.status, 200, path);
    assert.equal(res.headers.get('set-cookie'), null);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.doesNotMatch(await res.text(), /dummy-cookie-only/);
    for (const header of ['Authorization', 'Proxy-Authorization', 'X-Api-Key']) {
      assert.equal((await app.fetch(request(path, 'GET', undefined,
        { Cookie: cookie, [header]: 'dummy-only' }))).status, 400, path + ' ' + header);
    }
    assert.equal((await app.fetch(request(path, 'GET', undefined,
      { Cookie: cookie, Origin: 'https://evil.example' }))).status, 403);
  }
  for (const path of ['/', '/index.html', '/healthz']) {
    assert.equal((await app.fetch(request(path, 'POST', {}, { Cookie: cookie }))).status, 400);
  }
});

test('API routes still reject cookies and other credential headers before using session state', async () => {
  const app = createRelay({ origin });
  const session = await create(app);
  const path = '/api/session/' + session.session_id;
  for (const header of ['Cookie', 'Authorization', 'Proxy-Authorization', 'X-Api-Key']) {
    const headers = { [header]: 'dummy-only' };
    for (const [route, method, body] of [
      ['/api/session/create', 'POST', {}],
      [path + '/poll', 'GET', undefined],
      [path + '/submit', 'POST', { encrypted_payload: encrypted }],
      [path + '/submit', 'OPTIONS', undefined],
    ]) {
      assert.equal((await app.fetch(request(route, method, body, headers))).status, 400, route + ' ' + header);
    }
  }
  assert.equal((await app.fetch(request(path + '/poll'))).status, 204);
});

test('served portal explicitly omits browser credentials when submitting encrypted data', async () => {
  const app = createRelay({ origin });
  const session = await create(app);
  const page = await app.fetch(request('/?s=' + session.session_id));
  const script = (await page.text()).match(/<script>([\s\S]*?)<\/script>/)[1];
  const nodes = new Map(), listeners = {}, calls = [];
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, { value: '', disabled: false, innerHTML: '', style: {},
      classList: { add() {}, remove() {} }, addEventListener() {}, focus() {} });
    return nodes.get(id);
  };
  const context = vm.createContext({ TextEncoder, Uint8Array, DataView, URLSearchParams, crypto: webcrypto,
    setTimeout() {}, document: { getElementById: element, querySelectorAll: () => [] },
    window: { location: { search: '?s=' + session.session_id, hash: '#' + 'ab'.repeat(32) },
      addEventListener: (event, fn) => { listeners[event] = fn; },
      btoa: value => Buffer.from(value, 'binary').toString('base64') },
    fetch: async (path, options) => {
      calls.push({ path, options });
      return app.fetch(new Request(origin + path, options));
    },
  });
  vm.runInContext(script, context);
  listeners.DOMContentLoaded();
  element('keyInput').value = 'dummy-key-only';
  await vm.runInContext('submitKey()', context);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, '/api/session/' + session.session_id + '/submit');
  assert.equal(calls[0].options.credentials, 'omit');
  assert.deepEqual(Object.keys(calls[0].options.headers), ['Content-Type']);
  assert.doesNotMatch(calls[0].options.body, /dummy-key-only/);
  const ready = await (await app.fetch(request('/api/session/' + session.session_id + '/poll'))).json();
  assert.equal(ready.status, 'ready');
  assert.match(ready.payload, /^HMAC:/);
  assert.match(element('msgBox').textContent, /encrypted and sent successfully/);
});

test('portal retains QR URL flow and encrypts dummy data compatibly, without secret fallbacks', async () => {
  const app = createRelay({ origin });
  const page = await app.fetch(request('/?s=ABC234'));
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('referrer-policy'), 'no-referrer');
  assert.match(await page.text(), /window.location.hash/);
  const script = HTML_PAGE.match(/<script>([\s\S]*?)<\/script>/)[1];
  const context = vm.createContext({ TextEncoder, Uint8Array, DataView, URLSearchParams, crypto: webcrypto,
    window: { addEventListener() {}, btoa: s => Buffer.from(s, 'binary').toString('base64') }, document: {} });
  vm.runInContext(script, context);
  const secret = 'ab'.repeat(32);
  const data = { provider: 'claude', api_key: 'dummy-code-only#dummy-state' };
  const payload = await vm.runInContext(`encryptPayload(${JSON.stringify(data)}, '${secret}')`, context);
  const combined = Buffer.from(payload.slice(5), 'base64');
  const iv = combined.subarray(0, 16), tag = combined.subarray(16, 32), cipher = combined.subarray(32);
  const key = Buffer.from(secret, 'hex');
  const hmac = bytes => createHmac('sha256', key).update(bytes).digest();
  assert.deepEqual(tag, hmac(Buffer.concat([Buffer.from('AUTH'), iv, cipher])).subarray(0, 16));
  const plain = Buffer.alloc(cipher.length);
  for (let i = 0; i < cipher.length; i += 32) {
    const counter = Buffer.alloc(20); iv.copy(counter); counter.writeUInt32BE(i / 32, 16);
    const block = hmac(counter);
    for (let j = 0; j < 32 && i + j < cipher.length; j++) plain[i + j] = cipher[i + j] ^ block[j];
  }
  assert.deepEqual(JSON.parse(plain), data);
  for (const bad of ['', 'a'.repeat(32), 'g'.repeat(64), 'a'.repeat(65)]) {
    await assert.rejects(vm.runInContext(`encryptPayload({}, '${bad}')`, context), /Missing or invalid secret/);
  }
  await assert.rejects(vm.runInContext(`encryptPayload({api_key: 'x'.repeat(4096)}, '${secret}')`, context), /too large/);
  const session = await create(app);
  assert.equal((await app.fetch(request(`/api/session/${session.session_id}/submit`, 'POST', { encrypted_payload: payload }))).status, 200);
  assert.equal((await (await app.fetch(request(`/api/session/${session.session_id}/poll`))).json()).payload, payload);
});

test('real HTTP adapter round trip, health, streaming bounds and generic errors', async t => {
  const server = createServer({ origin });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(base + '/healthz')).status, 200);
  const created = await (await fetch(base + '/api/session/create', { method: 'POST', body: '{}' })).json();
  assert.match(created.session_id, /^[A-Z0-9]{6}$/);
  assert.equal((await fetch(base + `/api/session/${created.session_id}/poll`)).status, 204);
  assert.equal((await fetch(base + '/api/session/create', { method: 'POST', body: 'x'.repeat(LIMITS.maxBodyBytes + 1) })).status, 413);
  assert.equal((await fetch(base + '/', { headers: { Origin: 'https://evil.example' } })).status, 403);
  const status = await new Promise((resolve, reject) => {
    const req = http.request(base + '/api/session/create', { method: 'POST', headers: { 'Transfer-Encoding': 'chunked' } }, res => { res.resume(); resolve(res.statusCode); });
    req.on('error', reject);
    req.write('x'.repeat(LIMITS.maxBodyBytes)); req.end('x');
  });
  assert.equal(status, 413);
  assert.equal((await fetch(base + '/', { headers: { 'Content-Encoding': 'gzip' } })).status, 415);
});

test('Docker context excludes runtime state and preserves the MIT license', async () => {
  const docker = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8');
  const ignore = await readFile(new URL('../.dockerignore', import.meta.url), 'utf8');
  assert.match(docker, /FROM node:24-alpine/); assert.match(docker, /USER node/);
  assert.match(docker, /COPY --chown=node:node LICENSE/);
  assert.doesNotMatch(docker, /COPY\s+\.\s/); assert.match(ignore, /^\*\*/);
  assert.doesNotMatch(ignore, /!.*\.wrangler/);
});

test('portal blocks missing-fragment entry before asking for credentials', () => {
  for (const hash of ['', '#short', '#' + 'g'.repeat(64)]) {
    const nodes = new Map();
    const element = id => {
      if (!nodes.has(id)) nodes.set(id, { disabled: false, innerHTML: '', style: {}, classList: { add() {}, remove() {} }, addEventListener() {}, focus() {} });
      return nodes.get(id);
    };
    const listeners = {};
    const context = vm.createContext({ TextEncoder, Uint8Array, DataView, URLSearchParams, crypto: webcrypto,
      setTimeout() {}, document: { getElementById: element, querySelectorAll: () => [] },
      window: { location: { search: '?s=ABC234', hash }, addEventListener: (event, fn) => { listeners[event] = fn; } } });
    vm.runInContext(HTML_PAGE.match(/<script>([\s\S]*?)<\/script>/)[1], context);
    listeners.DOMContentLoaded();
    assert.equal(element('btnContinue').disabled, true);
    assert.equal(element('pairingCodeInput').disabled, true);
    assert.match(element('msgBox').textContent, /full QR link/);
    vm.runInContext('proceedToStep2()', context);
    assert.equal(element('formContent').innerHTML, '');
  }
});

test('valid full QR link opens the provider form; malformed session IDs do not', () => {
  for (const [search, expected] of [['?s=ABC234', true], ['?s=abc234', true], ['?s=ABCD', false], ['?s=ABC234/evil', false]]) {
    const nodes = new Map(), listeners = {};
    const element = id => {
      if (!nodes.has(id)) nodes.set(id, { disabled: false, innerHTML: '', style: {}, classList: { add() {}, remove() {} }, addEventListener() {}, focus() {} });
      return nodes.get(id);
    };
    const context = vm.createContext({ TextEncoder, Uint8Array, DataView, URLSearchParams, crypto: webcrypto,
      setTimeout() {}, document: { getElementById: element, querySelectorAll: () => [] },
      window: { location: { search, hash: '#' + 'ab'.repeat(32) }, addEventListener: (event, fn) => { listeners[event] = fn; } } });
    vm.runInContext(HTML_PAGE.match(/<script>([\s\S]*?)<\/script>/)[1], context);
    listeners.DOMContentLoaded();
    assert.equal(element('formContent').innerHTML.includes('keyInput'), expected);
    if (expected) assert.equal(element('activeSessionCode').textContent, 'ABC234');
  }
});
