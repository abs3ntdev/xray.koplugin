// MIT License. See ../LICENSE. Node HTTP adapter, no third-party dependencies.
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { createRelay, LIMITS, validateOrigin } from './app.mjs';

export function createServer({ origin, ...options } = {}) {
  origin = validateOrigin(origin);
  const relay = createRelay({ origin, ...options });
  const server = http.createServer({
    maxHeaderSize: 8192,
    requestTimeout: 15000,
    headersTimeout: 10000,
    keepAliveTimeout: 5000,
  }, async (req, res) => {
    const reject = (status, message) => {
      // Never reflect request data, headers, paths, session IDs or exceptions.
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', Connection: 'close' });
      res.end(JSON.stringify({ success: false, error: message }));
      req.resume();
    };
    try {
      if (!req.url?.startsWith('/') || req.url.startsWith('//') || /[\\#\s]/.test(req.url)) return reject(400, 'Invalid request target');
      if (!['GET', 'POST', 'OPTIONS'].includes(req.method)) return reject(405, 'Method not allowed');
      if (req.headers['content-encoding']) return reject(415, 'Encoded request bodies are not supported');
      if (Number(req.headers['content-length']) > LIMITS.maxBodyBytes) return reject(413, 'Request too large');
      const chunks = [];
      let bytes = 0;
      for await (const chunk of req) {
        bytes += chunk.length;
        if (bytes > LIMITS.maxBodyBytes) return reject(413, 'Request too large');
        chunks.push(chunk);
      }
      if (req.method !== 'POST' && bytes) return reject(400, 'Unexpected request body');
      const request = new Request(origin + req.url, {
        method: req.method,
        headers: req.headers,
        ...(req.method === 'POST' ? { body: Buffer.concat(chunks) } : {}),
      });
      const reply = await relay.fetch(request);
      res.writeHead(reply.status, Object.fromEntries(reply.headers));
      res.end(Buffer.from(await reply.arrayBuffer()));
    } catch {
      if (!res.headersSent) reject(500, 'Relay request failed');
      else res.destroy();
    }
  });
  server.maxConnections = 128;
  server.maxRequestsPerSocket = 100;
  server.setTimeout(15000, socket => socket.destroy());
  const cleanup = setInterval(() => relay.cleanup(), 30000);
  cleanup.unref();
  server.on('close', () => clearInterval(cleanup));
  server.on('clientError', (_error, socket) => {
    if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const port = Number(process.env.PORT || '8080');
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1-65535');
    const server = createServer({ origin: process.env.RELAY_ORIGIN });
    server.on('error', () => { console.error('Relay could not start'); process.exitCode = 1; });
    server.listen(port, '0.0.0.0', () => console.log(`X-Ray relay listening on port ${port}`));
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
      server.close();
      setTimeout(() => process.exit(0), 5000).unref();
    });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
