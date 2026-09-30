// MIT License. See ../LICENSE. This adapter uses the existing browser portal
// and ciphertext envelope; it never decrypts data or calls provider endpoints.
import { randomInt } from 'node:crypto';
import { HTML_PAGE } from '../cloudflare-worker/worker.js';

export const LIMITS = Object.freeze({
  ttlSeconds: 600,
  maxSessions: 256,
  maxBodyBytes: 16 * 1024,
  maxPayloadBytes: 8192,
  requestsPerMinute: 600,
  createsPerMinute: 30,
});
const SESSION = /^[A-Z0-9]{6}$/;
const ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const SECURITY_HEADERS = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Content-Security-Policy': "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
};

export function validateOrigin(value) {
  if (typeof value !== 'string' || value.length > 262 || /[\s\\?#@]/.test(value)) {
    throw new Error('RELAY_ORIGIN must be an HTTPS DNS origin, with no path, port, credentials, query or fragment');
  }
  const match = /^https:\/\/([a-zA-Z0-9.-]+)\/?$/.exec(value);
  const host = match?.[1].toLowerCase();
  const labels = host?.split('.');
  if (!host || host.length > 253 || labels.length < 2 || /^\d+(\.\d+)+$/.test(host)
      || labels.some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    throw new Error('RELAY_ORIGIN must be an HTTPS DNS origin, with no path, port, credentials, query or fragment');
  }
  return `https://${host}`;
}

function validPayload(value) {
  if (typeof value !== 'string' || value.length > LIMITS.maxPayloadBytes || !value.startsWith('HMAC:')) return false;
  const encoded = value.slice(5);
  if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return false;
  const raw = Buffer.from(encoded, 'base64');
  return raw.length > 32 && raw.toString('base64') === encoded;
}

// A fresh factory instance has no shared state, database, filesystem writes or
// secret configuration. Time/id injection is for deterministic tests only.
export function createRelay({ origin, now = Date.now, generateId = () =>
  Array.from({ length: 6 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('') } = {}) {
  origin = validateOrigin(origin);
  const sessions = new Map();
  let windowStart = now(), requests = 0, creates = 0;
  const response = (body, status = 200, extra = {}) => new Response(body, {
    status, headers: { ...SECURITY_HEADERS, ...extra },
  });
  const json = (data, status = 200, extra = {}) => response(JSON.stringify(data), status,
    { 'Content-Type': 'application/json', ...extra });
  const error = (message, status, extra) => json({ success: false, error: message }, status, extra);
  function cleanup() {
    const time = now();
    for (const [id, session] of sessions) if (session.expiresAt <= time) sessions.delete(id);
  }
  return {
    cleanup,
    async fetch(request) {
      cleanup();
      const url = new URL(request.url);
      if (url.origin !== origin) return error('Invalid relay origin', 400);
      const browserOrigin = request.headers.get('origin');
      if (browserOrigin && browserOrigin !== origin) return error('Cross-origin request rejected', 403);
      if (request.headers.has('authorization') || request.headers.has('cookie')
          || request.headers.has('proxy-authorization') || request.headers.has('x-api-key')) return error('Credentials are not accepted by the relay', 400);
      if (url.pathname === '/healthz' && request.method === 'GET') return json({ status: 'ok' });
      const time = now();
      if (time - windowStart >= 60000) { windowStart = time; requests = 0; creates = 0; }
      if (++requests > LIMITS.requestsPerMinute) return error('Relay request limit reached. Try again shortly.', 429, { 'Retry-After': '60' });
      if (request.method === 'OPTIONS') return response(null, 204, {
        'Access-Control-Allow-Origin': origin,
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Vary': 'Origin',
      });
      if (request.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
        return response(HTML_PAGE, 200, { 'Content-Type': 'text/html; charset=utf-8' });
      }
      if (url.pathname === '/api/session/create' && request.method === 'POST') {
        if (++creates > LIMITS.createsPerMinute) return error('Too many new sessions. Try again shortly.', 429, { 'Retry-After': '60' });
        if (sessions.size >= LIMITS.maxSessions) return error('Relay is full. Wait for existing sessions to expire.', 503, { 'Retry-After': '60' });
        let id;
        for (let attempt = 0; attempt < 10; attempt++) {
          const candidate = generateId();
          if (typeof candidate === 'string' && SESSION.test(candidate) && !sessions.has(candidate)) { id = candidate; break; }
        }
        if (!id) return error('Could not allocate a session. Try again.', 503);
        sessions.set(id, { expiresAt: time + LIMITS.ttlSeconds * 1000, payload: null });
        return json({ success: true, session_id: id, expires_in: LIMITS.ttlSeconds });
      }
      const match = /^\/api\/session\/([A-Za-z0-9]{6})\/(poll|submit)$/.exec(url.pathname);
      if (!match) return error('Not found', 404);
      const [, rawId, action] = match;
      if ((action === 'poll' && request.method !== 'GET') || (action === 'submit' && request.method !== 'POST')) {
        return error('Method not allowed', 405, { Allow: action === 'poll' ? 'GET' : 'POST' });
      }
      const session = sessions.get(rawId.toUpperCase());
      if (!session) return error('Session expired or not found', 404);
      if (action === 'poll') return session.payload
        ? json({ success: true, status: 'ready', payload: session.payload }) : response(null, 204);
      if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get('content-type') || '')) return error('Expected application/json', 415);
      // The HTTP adapter bounds bytes while streaming. Retain the bound here
      // too, so direct use of this Fetch handler cannot store large payloads.
      let body;
      try {
        const text = await request.text();
        if (Buffer.byteLength(text) > LIMITS.maxBodyBytes) return error('Request too large', 413);
        body = JSON.parse(text);
      } catch { return error('Malformed request payload', 400); }
      if (!body || Array.isArray(body) || typeof body !== 'object' || !validPayload(body.encrypted_payload)) {
        return error('Invalid encrypted payload', 400);
      }
      // First submission wins, but identical network retries are harmless.
      if (session.payload && session.payload !== body.encrypted_payload) return error('Session already submitted', 409);
      if (session.expiresAt <= now()) { cleanup(); return error('Session expired or not found', 404); }
      session.payload = body.encrypted_payload;
      return json({ success: true, message: 'Encrypted data sent to your e-reader.' });
    },
  };
}
