#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import { URL } from 'node:url';

const host = process.env.HOST || '127.0.0.1';
const port = Number.parseInt(process.env.PORT || '18082', 10);
const upstream = new URL(process.env.UPSTREAM || 'http://127.0.0.1:18081');
const maxBodyBytes = Number.parseInt(process.env.MAX_BODY_BYTES || String(32 * 1024 * 1024), 10);
const policyPath = process.env.FAST_POLICY_PATH || '/home/ubuntu/apps/sub2api-fast-policy/runtime.json';
const policyReloadMs = Number.parseInt(process.env.FAST_POLICY_RELOAD_MS || '2000', 10);

const injectablePaths = new Set([
  '/responses',
  '/v1/responses',
  '/v1/chat/completions',
  '/v1/completions',
]);

let policy = {
  defaultFast: false,
  fastKeyHashes: new Set(),
  blockedKeyHashes: new Set(),
  loadedAt: null,
  mtimeMs: 0,
};

function loadPolicy(force = false) {
  try {
    const stat = fs.statSync(policyPath);
    if (!force && stat.mtimeMs === policy.mtimeMs) return;

    const raw = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
    policy = {
      defaultFast: raw.defaultFast === true,
      fastKeyHashes: new Set(Array.isArray(raw.fastKeyHashes) ? raw.fastKeyHashes : []),
      blockedKeyHashes: new Set(Array.isArray(raw.blockedKeyHashes) ? raw.blockedKeyHashes : []),
      loadedAt: new Date().toISOString(),
      mtimeMs: stat.mtimeMs,
    };
    console.log(
      `fast policy loaded defaultFast=${policy.defaultFast} fast=${policy.fastKeyHashes.size} blocked=${policy.blockedKeyHashes.size}`,
    );
  } catch (err) {
    if (force) {
      console.warn(`fast policy unavailable at startup: ${err.message}; defaulting to normal tier`);
    }
  }
}

function bearerToken(req) {
  const auth = req.headers.authorization || req.headers.Authorization || '';
  const match = String(auth).match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : '';
}

function tokenHash(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

function shouldUseFast(req) {
  const token = bearerToken(req);
  if (!token) return false;

  const hash = tokenHash(token);
  if (policy.blockedKeyHashes.has(hash)) return false;
  if (policy.fastKeyHashes.has(hash)) return true;
  return policy.defaultFast === true;
}

function shouldRewrite(req) {
  if (req.method !== 'POST') return false;
  const path = new URL(req.url, 'http://127.0.0.1').pathname;
  if (!injectablePaths.has(path)) return false;
  const contentType = req.headers['content-type'] || '';
  return contentType.toLowerCase().includes('application/json');
}

function requestPath(req) {
  return new URL(req.url, 'http://127.0.0.1').pathname;
}

function copyHeaders(headers) {
  const out = { ...headers };
  delete out.host;
  delete out['content-length'];
  delete out.connection;
  delete out['proxy-connection'];
  return out;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBodyBytes) {
        reject(Object.assign(new Error('request body too large'), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function forward(req, res, body) {
  const target = new URL(req.url, upstream);
  const headers = copyHeaders(req.headers);
  if (body) headers['content-length'] = Buffer.byteLength(body);

  const upstreamReq = http.request({
    protocol: target.protocol,
    hostname: target.hostname,
    port: target.port,
    method: req.method,
    path: target.pathname + target.search,
    headers,
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstreamReq.on('error', (err) => {
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
    }
    res.end(JSON.stringify({ error: 'upstream_error', message: err.message }));
  });

  if (body) {
    upstreamReq.end(body);
  } else {
    req.pipe(upstreamReq);
  }
}

function stripResponsesInputNamespaces(payload, path) {
  if (path !== '/responses' && path !== '/v1/responses') return 0;
  if (!payload || typeof payload !== 'object' || !('input' in payload)) return 0;

  let removed = 0;
  const visit = (value) => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item);
      return;
    }
    if (!value || typeof value !== 'object') return;

    if (Object.prototype.hasOwnProperty.call(value, 'namespace')) {
      delete value.namespace;
      removed += 1;
    }
    for (const child of Object.values(value)) visit(child);
  };

  visit(payload.input);
  return removed;
}

const server = http.createServer(async (req, res) => {
  try {
    if (!shouldRewrite(req)) {
      forward(req, res);
      return;
    }

    const original = await readBody(req);
    let payload;
    try {
      payload = JSON.parse(original.toString('utf8'));
    } catch {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'invalid_json' }));
      return;
    }

    const path = requestPath(req);
    if (shouldUseFast(req)) {
      payload.service_tier = 'priority';
    } else {
      delete payload.service_tier;
    }
    const strippedNamespaces = stripResponsesInputNamespaces(payload, path);
    if (strippedNamespaces > 0) {
      console.warn(`stripped ${strippedNamespaces} unsupported responses input namespace field(s) path=${path}`);
    }

    const body = Buffer.from(JSON.stringify(payload));
    forward(req, res, body);
  } catch (err) {
    const statusCode = err.statusCode || 500;
    if (!res.headersSent) {
      res.writeHead(statusCode, { 'content-type': 'application/json' });
    }
    res.end(JSON.stringify({ error: 'injector_error', message: err.message }));
  }
});

server.on('clientError', (_err, socket) => {
  socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

loadPolicy(true);
setInterval(() => loadPolicy(false), Math.max(policyReloadMs, 500)).unref();

server.listen(port, host, () => {
  console.log(`sub2api-fast-injector listening on http://${host}:${port}, upstream ${upstream.href}`);
});
