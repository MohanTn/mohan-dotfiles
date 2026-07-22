#!/usr/bin/env node
/**
 * featurePlan-serve.js — one-command interactive mode launcher.
 *
 * Starts the WebSocket listener, bridges questions to the driving AI through
 * JSONL files (harness-agnostic: Claude Code, Copilot CLI, and Pi all just
 * read/write files), and opens the plan in the browser — including from WSL,
 * where the Windows browser is reached via wslview or powershell.exe.
 *
 * Usage: node featurePlan-serve.js <plan.html> [--port 3001] [--no-open]
 *
 * Bridge protocol (JSONL, one object per line, in the plan's directory):
 *   featurePlan-questions.jsonl  ← appended by this process:
 *       { id, section, question, plan }
 *   featurePlan-answers.jsonl    ← appended by the AI harness:
 *       { id, response, patches?: [{ type:'patch', section, itemId, field, value, action }] }
 */

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const QUESTIONS_FILE = 'featurePlan-questions.jsonl';
const ANSWERS_FILE = 'featurePlan-answers.jsonl';
const ANSWER_TIMEOUT_MS = 10 * 60 * 1000;
const PORT_RETRIES = 10;

// 'wsl' | 'linux' | 'darwin' | other process.platform values.
// Injectable env/reader for tests.
function detectPlatform(env = process.env, readProcVersion = defaultReadProcVersion) {
  if (process.platform === 'darwin') return 'darwin';
  if (env.WSL_DISTRO_NAME || env.WSL_INTEROP) return 'wsl';
  if (/microsoft/i.test(readProcVersion())) return 'wsl';
  return process.platform;
}

function defaultReadProcVersion() {
  try { return fs.readFileSync('/proc/version', 'utf-8'); } catch (e) { return ''; }
}

function urlFor(htmlPath, port) {
  return `file://${path.resolve(htmlPath)}?socket-port=${port}`;
}

// From WSL the Windows browser cannot read a Linux file:// path; translate it
// with wslpath -w (\\wsl.localhost\Distro\...) and rebuild the URL.
function windowsUrlFor(htmlPath, port, execFileSyncFn) {
  const execFileSync = execFileSyncFn || require('child_process').execFileSync;
  const winPath = execFileSync('wslpath', ['-w', path.resolve(htmlPath)]).toString().trim();
  const slashed = winPath.replace(/\\/g, '/');
  // UNC (\\wsl.localhost\...) becomes file://wsl.localhost/...; a drive path
  // (C:/...) needs the empty-authority file:///C:/... form.
  const base = slashed.startsWith('//') ? `file:${slashed}` : `file:///${slashed}`;
  return `${base}?socket-port=${port}`;
}

// Ordered opener candidates per platform. Each is [command, args]. Failures
// fall through to the next candidate; running out is non-fatal (the URL is
// always printed).
function openerCandidates(platform, htmlPath, port, execFileSyncFn) {
  const url = urlFor(htmlPath, port);
  if (platform === 'wsl') {
    let winUrl;
    try { winUrl = windowsUrlFor(htmlPath, port, execFileSyncFn); } catch (e) { winUrl = url; }
    return [
      ['wslview', [winUrl]],
      ['powershell.exe', ['-NoProfile', '-Command', `Start-Process '${winUrl}'`]]
    ];
  }
  if (platform === 'darwin') return [['open', [url]]];
  return [['xdg-open', [url]]];
}

function openBrowser(candidates, spawnFn = spawn) {
  const tryNext = (i) => {
    if (i >= candidates.length) {
      console.log('[featurePlan] Could not auto-open a browser; open the URL above manually.');
      return;
    }
    const [cmd, args] = candidates[i];
    const child = spawnFn(cmd, args, { detached: true, stdio: 'ignore' });
    child.on('error', () => tryNext(i + 1));
    if (child.unref) child.unref();
  };
  tryNext(0);
}

// File-based bridge: questions out, answers in. Returns an aiAgent function
// compatible with featurePlan-harness-listener, plus a close() for cleanup.
function createBridgeAgent(dir, options = {}) {
  const questionsPath = path.join(dir, QUESTIONS_FILE);
  const answersPath = path.join(dir, ANSWERS_FILE);
  const timeoutMs = options.timeoutMs || ANSWER_TIMEOUT_MS;

  fs.appendFileSync(answersPath, ''); // ensure it exists so watching works
  let offset = fs.statSync(answersPath).size; // only future answers count
  const pending = new Map();
  let counter = 0;

  function drain() {
    let size;
    try { size = fs.statSync(answersPath).size; } catch (e) { return; }
    if (size <= offset) return;
    const buf = Buffer.alloc(size - offset);
    const fd = fs.openSync(answersPath, 'r');
    try { fs.readSync(fd, buf, 0, buf.length, offset); } finally { fs.closeSync(fd); }
    // Only consume complete lines; a partially written line stays for later.
    const lastNewline = buf.lastIndexOf(0x0a);
    if (lastNewline === -1) return;
    const chunk = buf.slice(0, lastNewline + 1).toString('utf-8');
    offset += lastNewline + 1;
    for (const line of chunk.split('\n')) {
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch (e) {
        console.warn(`[featurePlan] Skipping malformed answer line: ${line.slice(0, 80)}`);
        continue;
      }
      const waiter = pending.get(msg.id);
      if (waiter) {
        pending.delete(msg.id);
        clearTimeout(waiter.timer);
        waiter.resolve({ response: msg.response || '', patches: msg.patches });
      }
    }
  }

  const watcher = fs.watch(dir, (event, name) => {
    if (name === ANSWERS_FILE) drain();
  });
  // fs.watch can miss events on some filesystems (notably 9p/DrvFs under
  // WSL); a slow poll guarantees answers are picked up.
  const poller = setInterval(drain, 1000);

  async function bridgeAgent(input) {
    const id = `${Date.now().toString(36)}-${counter++}`;
    fs.appendFileSync(questionsPath, JSON.stringify({
      id,
      section: input.section,
      question: input.question,
      plan: input.plan
    }) + '\n');
    console.log(`[featurePlan] Question ${id} appended to ${questionsPath} — answer via ${answersPath}`);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (pending.has(id)) {
          pending.delete(id);
          resolve({ response: `(No answer for question ${id} within ${Math.round(timeoutMs / 60000)} minutes.)` });
        }
      }, timeoutMs);
      pending.set(id, { resolve, timer });
    });
  }

  bridgeAgent.close = () => {
    watcher.close();
    clearInterval(poller);
    for (const { timer } of pending.values()) clearTimeout(timer);
    pending.clear();
  };
  return bridgeAgent;
}

// Starts the listener, walking ports on EADDRINUSE. Resolves { server, port }.
async function startListener(basePort, aiAgent) {
  const { createServer } = require('./featurePlan-harness-listener');
  let lastErr;
  for (let port = basePort; port <= basePort + PORT_RETRIES; port++) {
    const server = createServer(port, { aiAgent });
    try {
      await server.start();
      return { server, port };
    } catch (err) {
      lastErr = err;
      if (err && err.code !== 'EADDRINUSE') throw err;
    }
  }
  throw new Error(`No free port in ${basePort}-${basePort + PORT_RETRIES}: ${lastErr && lastErr.message}`);
}

async function serve(htmlPath, options = {}) {
  const basePort = options.port || 3001;
  const open = options.open !== false;
  const bridge = createBridgeAgent(path.dirname(path.resolve(htmlPath)), options);
  const { server, port } = await startListener(basePort, bridge);
  const url = urlFor(htmlPath, port);
  if (open) {
    openBrowser(openerCandidates(detectPlatform(), htmlPath, port), options.spawnFn);
  }
  console.log(`Open: ${url}`);
  return {
    server,
    port,
    url,
    stop: async () => {
      bridge.close();
      await server.stop();
    }
  };
}

function main() {
  const args = process.argv.slice(2);
  const htmlPath = args.find(a => !a.startsWith('--'));
  const portIdx = args.indexOf('--port');
  const port = portIdx !== -1 ? Number(args[portIdx + 1]) : 3001;
  const open = !args.includes('--no-open');

  if (!htmlPath || !Number.isInteger(port)) {
    console.error('Usage: node featurePlan-serve.js <plan.html> [--port 3001] [--no-open]');
    process.exit(1);
  }
  if (!fs.existsSync(htmlPath)) {
    console.error(`Error: plan HTML not found: ${htmlPath}`);
    process.exit(1);
  }

  serve(htmlPath, { port, open }).catch(err => {
    if (err.code === 'MODULE_NOT_FOUND' && /['"]ws['"]/.test(err.message)) {
      console.error('Error: ws module not found — run `npm install` in the feature-plan skill directory.');
    } else {
      console.error(`Error: ${err.message}`);
    }
    process.exit(1);
  });
}

if (require.main === module) {
  main();
}

module.exports = {
  detectPlatform,
  urlFor,
  windowsUrlFor,
  openerCandidates,
  openBrowser,
  createBridgeAgent,
  startListener,
  serve,
  QUESTIONS_FILE,
  ANSWERS_FILE
};
