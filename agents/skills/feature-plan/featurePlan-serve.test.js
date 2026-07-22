#!/usr/bin/env node
// Unit tests for featurePlan-serve.js. Run with: node --test featurePlan-serve.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Same guard as featurePlan-harness-listener.test.js: the nix sandbox has no
// node_modules, so skip cleanly when ws is unavailable.
let WebSocket;
try {
  WebSocket = require('ws');
} catch (err) {
  if (err.code === 'MODULE_NOT_FOUND' && err.message.includes('ws')) {
    console.log('⊘ Skipping serve tests: ws module not found (run npm install)');
    process.exit(0);
  }
  throw err;
}

const {
  detectPlatform,
  urlFor,
  openerCandidates,
  openBrowser,
  createBridgeAgent,
  startListener,
  serve,
  QUESTIONS_FILE,
  ANSWERS_FILE
} = require('./featurePlan-serve.js');

test('detectPlatform: wsl via WSL_DISTRO_NAME env', () => {
  if (process.platform === 'darwin') return; // darwin short-circuits by design
  assert.strictEqual(detectPlatform({ WSL_DISTRO_NAME: 'Ubuntu' }, () => ''), 'wsl');
});

test('detectPlatform: wsl via /proc/version microsoft marker', () => {
  if (process.platform === 'darwin') return;
  assert.strictEqual(
    detectPlatform({}, () => 'Linux version 5.15.90.1-microsoft-standard-WSL2'),
    'wsl'
  );
});

test('detectPlatform: plain linux when no WSL markers', () => {
  if (process.platform !== 'linux') return;
  assert.strictEqual(detectPlatform({}, () => 'Linux version 6.1.0 (gcc)'), 'linux');
});

test('urlFor builds a file URL with the socket-port query', () => {
  const url = urlFor('plan.html', 3005);
  assert.ok(url.startsWith('file:///'));
  assert.ok(url.endsWith('plan.html?socket-port=3005'));
});

test('openerCandidates: linux uses xdg-open, wsl prefers wslview with a Windows URL', () => {
  const linux = openerCandidates('linux', 'plan.html', 3001);
  assert.strictEqual(linux[0][0], 'xdg-open');

  const fakeWslpath = (cmd, args) => {
    assert.strictEqual(cmd, 'wslpath');
    return Buffer.from('\\\\wsl.localhost\\Ubuntu' + args[1].replace(/\//g, '\\') + '\n');
  };
  const wsl = openerCandidates('wsl', 'plan.html', 3001, fakeWslpath);
  assert.strictEqual(wsl[0][0], 'wslview');
  assert.ok(wsl[0][1][0].startsWith('file://wsl.localhost/Ubuntu'));
  assert.ok(wsl[0][1][0].endsWith('?socket-port=3001'));
  assert.strictEqual(wsl[1][0], 'powershell.exe');
});

test('openBrowser falls through to the next candidate on spawn error', () => {
  const attempted = [];
  const spawnFn = (cmd) => {
    attempted.push(cmd);
    const handlers = {};
    const child = {
      on: (evt, cb) => { handlers[evt] = cb; },
      unref: () => {}
    };
    if (cmd === 'missing-opener') {
      queueMicrotask(() => handlers.error(new Error('ENOENT')));
    }
    return child;
  };
  openBrowser([['missing-opener', []], ['works', []]], spawnFn);
  return new Promise(resolve => setImmediate(() => {
    assert.deepStrictEqual(attempted, ['missing-opener', 'works']);
    resolve();
  }));
});

test('bridge: question appends one JSONL line and an answer resolves it', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-bridge-'));
  const bridge = createBridgeAgent(dir, { timeoutMs: 5000 });
  try {
    const promise = bridge({ section: 'files', question: 'Why singleton?', plan: { title: 'T' } });

    const qLines = fs.readFileSync(path.join(dir, QUESTIONS_FILE), 'utf-8').trim().split('\n');
    assert.strictEqual(qLines.length, 1);
    const q = JSON.parse(qLines[0]);
    assert.strictEqual(q.section, 'files');
    assert.strictEqual(q.question, 'Why singleton?');
    assert.ok(q.id);

    fs.appendFileSync(path.join(dir, ANSWERS_FILE), JSON.stringify({
      id: q.id,
      response: 'Because state is shared.',
      patches: [{ type: 'patch', section: 'files', itemId: 'f-1', field: 'description', value: 'x', action: 'update' }]
    }) + '\n');

    const result = await promise;
    assert.strictEqual(result.response, 'Because state is shared.');
    assert.strictEqual(result.patches.length, 1);
  } finally {
    bridge.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('bridge: malformed answer lines are skipped, later valid line still resolves', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-bridge-'));
  const bridge = createBridgeAgent(dir, { timeoutMs: 5000 });
  try {
    const promise = bridge({ section: 'edgeCases', question: 'q', plan: {} });
    const q = JSON.parse(fs.readFileSync(path.join(dir, QUESTIONS_FILE), 'utf-8').trim());
    fs.appendFileSync(path.join(dir, ANSWERS_FILE),
      'not-json at all\n' + JSON.stringify({ id: q.id, response: 'ok' }) + '\n');
    const result = await promise;
    assert.strictEqual(result.response, 'ok');
  } finally {
    bridge.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('bridge: times out with a non-crashing placeholder response', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-bridge-'));
  const bridge = createBridgeAgent(dir, { timeoutMs: 50 });
  try {
    const result = await bridge({ section: 'files', question: 'q', plan: {} });
    assert.ok(result.response.includes('No answer'));
  } finally {
    bridge.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('startListener walks to the next port when the base port is busy', async () => {
  const net = require('node:net');
  const blocker = net.createServer();
  await new Promise(resolve => blocker.listen(0, resolve));
  const basePort = blocker.address().port;

  const agent = async () => ({ response: 'x' });
  const { server, port } = await startListener(basePort, agent);
  try {
    assert.ok(port > basePort && port <= basePort + 10, `expected fallback port, got ${port}`);
  } finally {
    await server.stop();
    blocker.close();
  }
});

test('serve: end-to-end question round-trip over a real socket', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-serve-'));
  const htmlPath = path.join(dir, 'plan.html');
  fs.writeFileSync(htmlPath, '<html></html>');

  const session = await serve(htmlPath, { port: 3401, open: false, timeoutMs: 5000 });
  try {
    assert.ok(session.url.includes(`?socket-port=${session.port}`));

    const ws = new WebSocket(`ws://localhost:${session.port}`);
    await new Promise((resolve, reject) => { ws.on('open', resolve); ws.on('error', reject); });

    const gotResponse = new Promise(resolve => {
      ws.on('message', (raw) => {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'response') resolve(msg);
      });
    });
    ws.send(JSON.stringify({ type: 'question', section: 'files', question: 'Q?', plan: {} }));

    // Answer arrives via the JSONL bridge, as a harness would write it.
    const qPath = path.join(dir, QUESTIONS_FILE);
    await new Promise(resolve => {
      const iv = setInterval(() => { if (fs.existsSync(qPath)) { clearInterval(iv); resolve(); } }, 20);
    });
    const q = JSON.parse(fs.readFileSync(qPath, 'utf-8').trim());
    fs.appendFileSync(path.join(dir, ANSWERS_FILE), JSON.stringify({ id: q.id, response: 'bridged!' }) + '\n');

    const msg = await gotResponse;
    assert.strictEqual(msg.text, 'bridged!');
    ws.close();
  } finally {
    await session.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
