import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderStatus } from '../src/status-renderer.js';
import { problems, routeRows } from '../src/dashboard.js';

// The macOS menu bar app decodes /teamclaude/status and /teamclaude/quota from
// JSON fixtures under macos/Tests/TeamClaudeCoreTests/Fixtures. Two things keep
// those fixtures honest from the proxy's side: the proxy's own consumers of the
// same payloads (`teamclaude status`, the dashboard page) accept every fixture,
// and a live headless server emits no key the reference fixture lacks — so a
// new or renamed server field fails here, naming the key, instead of never
// reaching the Swift decoder tests.

const fixturesDir = fileURLToPath(new URL('../macos/Tests/TeamClaudeCoreTests/Fixtures/', import.meta.url));
const cliPath = fileURLToPath(new URL('../src/index.js', import.meta.url));
const STATUS_REFERENCE = 'status-1.1.20.json';
const QUOTA_REFERENCE = 'quota-live.json';

const statusFixtures = readdirSync(fixturesDir).filter(name => /^status-.*\.json$/.test(name)).sort();

async function fixture(name) {
  return JSON.parse(await readFile(join(fixturesDir, name), 'utf8'));
}

test('the reference fixtures are among the Swift fixtures', () => {
  assert.ok(statusFixtures.includes(STATUS_REFERENCE), `${STATUS_REFERENCE} not found in ${fixturesDir}`);
  assert.ok(readdirSync(fixturesDir).includes(QUOTA_REFERENCE), `${QUOTA_REFERENCE} not found in ${fixturesDir}`);
});

// Every well-formed status fixture goes through the same three consumers the
// proxy itself runs on this payload. They may render less; they may not throw.
// The hostile fixture (wrong types in the right places) is the Swift decoder's
// corpus: the Node renderers only ever see their own server's output.
for (const name of statusFixtures.filter(n => !n.includes('hostile'))) {
  test(`${name} is accepted by renderStatus, routeRows and problems`, async () => {
    const status = await fixture(name);

    const text = renderStatus(status, { color: false });
    assert.equal(typeof text, 'string');
    assert.match(text, /^TeamClaude status\n/);

    const rows = routeRows(status);
    assert.ok(Array.isArray(rows));
    for (const row of rows) {
      assert.ok(row.kind === 'route' || row.kind === 'default', `unexpected row kind ${row.kind}`);
      assert.ok(Array.isArray(row.eligible) && Array.isArray(row.ineligible));
    }

    const list = problems(status);
    assert.ok(Array.isArray(list));
    for (const problem of list) {
      assert.ok(problem.severity === 'bad' || problem.severity === 'warn', `unexpected severity ${problem.severity}`);
      assert.equal(typeof problem.text, 'string');
    }
  });
}

test(`${STATUS_REFERENCE} renders the same picture the app derives from it`, async () => {
  const status = await fixture(STATUS_REFERENCE);

  const text = renderStatus(status, { color: false });
  for (const account of status.accounts) assert.ok(text.includes(account.name), `${account.name} missing from the rendered status`);
  assert.match(text, new RegExp(`^> ${status.currentAccount.replace(/[.@]/g, '\\$&')}`, 'm'), 'the current account carries the > marker');

  const rows = routeRows(status);
  assert.deepEqual(rows.map(r => r.kind), ['route', 'default']);
  assert.equal(rows[0].name, status.routes[0].name);
  assert.equal(rows[0].target, status.routes[0].target);
  assert.equal(rows[1].target, status.defaultTarget);

  assert.deepEqual(problems(status), [], 'a healthy fleet has no banner');
});

// --- drift alarm: a live server against the reference fixtures -----------

// A port nothing is listening on: bind one, learn its number, give it back.
function closedPort() {
  return new Promise(resolve => {
    const probe = net.createServer();
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function startServer(configPath) {
  const child = spawn(process.execPath, [cliPath, 'server', '--headless'], {
    env: { ...process.env, TEAMCLAUDE_CONFIG: configPath, TEAMCLAUDE_DISABLE_AUTOUPDATE: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', c => { output += c; });
  child.stderr.on('data', c => { output += c; });
  const stop = async () => {
    child.kill('SIGTERM');
    const killer = setTimeout(() => child.kill('SIGKILL'), 5000);
    // Node does not replay 'exit' to late listeners: a child that died before
    // stop() ran must not hang the await. No await between check and attach.
    if (child.exitCode === null && child.signalCode === null) {
      await new Promise(resolve => child.on('exit', resolve));
    }
    clearTimeout(killer);
  };
  return { child, stop, output: () => output };
}

async function waitForServer(port, childOutput) {
  const deadline = Date.now() + 10_000;
  for (;;) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/teamclaude/status`);
      if (res.ok) return;
    } catch { /* not up yet */ }
    if (Date.now() > deadline) throw new Error(`server did not start:\n${childOutput()}`);
    await new Promise(r => setTimeout(r, 100));
  }
}

// One apikey account, dead upstream, no proxy: the server answers both control
// endpoints without ever reaching the network.
async function withServer(fn) {
  const deadPort = await closedPort();
  const proxyPort = await closedPort();
  const dir = await mkdtemp(join(tmpdir(), 'teamclaude-macos-fixtures-'));
  const configPath = join(dir, 'config.json');
  await writeFile(configPath, JSON.stringify({
    proxy: { port: proxyPort, apiKey: 'tc-test' },
    upstream: `http://127.0.0.1:${deadPort}`,
    upstreamProxy: false,
    accounts: [{ name: 'api-test', type: 'apikey', apiKey: 'sk-ant-api03-placeholder' }],
  }));

  const server = startServer(configPath);
  try {
    await waitForServer(proxyPort, server.output);
    await fn(proxyPort);
  } finally {
    await server.stop();
    await rm(dir, { recursive: true, force: true });
  }
}

function keysOf(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? Object.keys(value) : [];
}

// Every key the live payload carries at `path` must exist in the reference at
// the same path. Collected rather than asserted one by one so a regeneration
// happens once, with the whole list in hand.
function missingKeys(live, reference, path) {
  const known = new Set(keysOf(reference));
  return keysOf(live).filter(key => !known.has(key)).map(key => (path ? `${path}.${key}` : key));
}

function assertCovered(missing, referenceName) {
  assert.deepEqual(missing, [], `${referenceName} is missing key${missing.length === 1 ? '' : 's'} ${missing.join(', ')} — regenerate the Swift fixture from a live server`);
}

test(`a live /teamclaude/status emits no key ${STATUS_REFERENCE} lacks`, async () => {
  const reference = await fixture(STATUS_REFERENCE);
  assert.ok(reference.accounts.length >= 1, 'the reference fixture must carry at least one account');

  await withServer(async port => {
    const res = await fetch(`http://127.0.0.1:${port}/teamclaude/status`);
    assert.equal(res.status, 200);
    const live = await res.json();
    assert.equal(live.currentAccount, 'api-test', 'the server answered with the throwaway config');

    const missing = [
      ...missingKeys(live, reference, ''),
      ...['server', 'sessions', 'probe', 'warm'].flatMap(key => missingKeys(live[key], reference[key], key)),
      ...['probe', 'warm'].flatMap(key => (live[key]?.accounts || []).flatMap(row => missingKeys(row, reference[key]?.accounts?.[0], `${key}.accounts[]`))),
      ...live.accounts.flatMap(account => [
        ...missingKeys(account, reference.accounts[0], 'accounts[]'),
        ...missingKeys(account.quota, reference.accounts[0].quota, 'accounts[].quota'),
        ...missingKeys(account.usage, reference.accounts[0].usage, 'accounts[].usage'),
      ]),
    ];
    assertCovered([...new Set(missing)], STATUS_REFERENCE);
  });
});

test(`a live /teamclaude/quota emits no key ${QUOTA_REFERENCE} lacks`, async () => {
  const reference = await fixture(QUOTA_REFERENCE);
  assert.ok(reference.accounts.length >= 1, 'the reference fixture must carry at least one account');

  await withServer(async port => {
    const res = await fetch(`http://127.0.0.1:${port}/teamclaude/quota`);
    assert.equal(res.status, 200);
    const live = await res.json();
    assert.deepEqual(live.accounts.map(a => a.name), ['api-test'], 'the server answered with the throwaway config');

    const missing = [
      ...missingKeys(live, reference, ''),
      ...['aggregate', 'warmup'].flatMap(key => missingKeys(live[key], reference[key], key)),
      ...live.accounts.flatMap(account => [
        ...missingKeys(account, reference.accounts[0], 'accounts[]'),
        ...missingKeys(account.tier, reference.accounts[0].tier, 'accounts[].tier'),
        ...missingKeys(account.buckets, reference.accounts[0].buckets, 'accounts[].buckets'),
      ]),
    ];
    assertCovered([...new Set(missing)], QUOTA_REFERENCE);
  });
});
