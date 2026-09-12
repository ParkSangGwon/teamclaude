#!/usr/bin/env node
// A stand-in control plane for screenshots and UI work: answers /teamclaude/status
// and /teamclaude/quota from the Swift test fixtures (example.com accounts, no
// credentials), with every timestamp shifted so the windows are live now.
// `POST /teamclaude/switch` moves the current account; `/reload` says ok.
//
//   node macos/scripts/demo-server.mjs [--port 3458] [--status <fixture>] [--quota <fixture>]
//
// Point the app at it with a throwaway config whose proxy.port matches (see
// scripts/demo-config.sh), never with the real ~/.config/teamclaude.json.
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const fixtures = fileURLToPath(new URL('../Tests/TeamClaudeCoreTests/Fixtures/', import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const port = Number(opt('--port', 3458));
const status = JSON.parse(readFileSync(fixtures + opt('--status', 'status-1.1.20.json'), 'utf8'));
const quota = JSON.parse(readFileSync(fixtures + opt('--quota', 'quota-live.json'), 'utf8'));

// The fixture's own "now": the newest session activity. Everything moves by the same delta.
const fixtureNow = Math.max(...(status.sessions?.items ?? []).map(s => s.lastSeen ?? 0), Date.parse(status.server?.startedAt ?? 0));
const delta = Date.now() - fixtureNow;
const isMs = v => typeof v === 'number' && v > 1e12;
const isIso = v => typeof v === 'string' && /^\d{4}-\d\d-\d\dT.*Z$/.test(v);
function shifted(value) {
  if (Array.isArray(value)) return value.map(shifted);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, shifted(v)]));
  if (isMs(value)) return value + delta;
  if (isIso(value)) return new Date(Date.parse(value) + delta).toISOString();
  return value;
}

function switchTo(name) {
  const acct = status.accounts.find(a => a.name === name);
  if (!acct) return { ok: false, error: `no account named ${name}` };
  status.currentAccount = name;
  if (status.currentAccounts) status.currentAccounts[acct.provider ?? 'anthropic'] = name;
  status.defaultTarget = name;
  if (status.defaultTargets) status.defaultTargets[acct.provider ?? 'anthropic'] = name;
  for (const r of status.routes ?? []) if (r.accounts.some(a => a.name === name && a.eligible)) r.target = name;
  return { ok: true, account: name, eligible: true };
}

const server = http.createServer((req, res) => {
  const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  const url = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'GET' && url.pathname === '/teamclaude/status') {
    const s = shifted(status);
    s.server = { ...s.server, uptimeSeconds: Math.round((Date.now() - Date.parse(s.server.startedAt)) / 1000) };
    return send(200, s);
  }
  if (req.method === 'GET' && url.pathname === '/teamclaude/quota') return send(200, shifted(quota));
  if (req.method === 'POST' && url.pathname === '/teamclaude/reload') return send(200, { ok: true, added: 0 });
  if (req.method === 'POST' && url.pathname === '/teamclaude/switch') {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => { try { send(200, switchTo(JSON.parse(body).account)); } catch (e) { send(400, { ok: false, error: String(e) }); } });
    return;
  }
  if (req.method === 'GET' && url.pathname === '/teamclaude/dashboard') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<title>demo</title>'); }
  send(404, { ok: false, error: 'not found' });
});
server.listen(port, '127.0.0.1', () => console.log(`demo control plane on http://127.0.0.1:${port} (fixture time shifted by ${Math.round(delta / 3600000)} h)`));
