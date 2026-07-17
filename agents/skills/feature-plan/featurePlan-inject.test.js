#!/usr/bin/env node
// Unit tests for featurePlan-inject.js. Run with: node --test agents/skills/featurePlan/featurePlan-inject.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const {
  escapeHtml,
  toScriptJson,
  normalizePlan,
  injectContent,
  loadTemplate,
  SECTIONS,
  ITEM_FIELD_DEFAULTS
} = require('./featurePlan-inject.js');

const TEMPLATE_PATH = path.join(__dirname, 'featurePlan-template.html');

function sampleConfig(overrides = {}) {
  return {
    title: 'Add two-factor authentication',
    module: 'User Service',
    goal: 'As a user, I want to require a second factor at login so that a stolen password alone cannot compromise my account.',
    context: 'Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.',
    patternCore: 'Layered (Controller -> Service -> Repository)',
    patternBusiness: 'Transaction Script',
    patternSpecific: 'Use Repository for User; Factory for OTP enrollment DTO.',
    patternOverrides: 'No separate Repository for OTP — reuse UserRepository.',
    files: [
      { id: 'f1', order: 1, action: 'create', path: 'src/Security/TotpService.php', description: 'TOTP enrollment + verification', pseudoCode: 'class TotpService {\n  public function enroll(User $user): string { /* generate secret */ }\n  public function verify(User $user, string $code): bool { /* check code */ }\n}' },
      { id: 'f2', order: 2, action: 'update', path: 'src/Auth/AuthService.php', description: 'Wire TOTP into login flow', pseudoCode: 'public function login($email, $password, $code) { /* verify + then 2fa */ }' }
    ],
    logicSteps: [
      { id: 'l1', step: 'Validate credentials', pseudo: '1. Check email format\n2. Look up user\n3. Verify password_hash' }
    ],
    contracts: [
      { id: 'c1', name: 'POST /api/v2/verify-2fa', inputs: '{ userId: string, code: string }', outputs: '{ ok: boolean, reason?: string }' }
    ],
    edgeCases: [
      { id: 'e1', condition: 'User has 2FA enabled but no code provided', handling: 'Return 401 with reason "2fa_required".' }
    ],
    testScenarios: [
      { id: 't1', target: 'TotpService::enroll()', scenario: 'Returns a base32 secret that decodes to 20+ digits.' },
      { id: 't2', target: 'AuthService::login() with bad code', scenario: 'Returns 401 and increments failed_2fa counter.' }
    ],
    ...overrides
  };
}

test('escapeHtml escapes all HTML-sensitive characters', () => {
  assert.strictEqual(
    escapeHtml(`<b>"x" & 'y'</b>`),
    '&lt;b&gt;&quot;x&quot; &amp; &#039;y&#039;&lt;/b&gt;'
  );
});

test('toScriptJson escapes </script> breakout and line separators', () => {
  const json = toScriptJson({ text: '</script><script>alert(1)</script>  ' });
  assert.ok(!json.includes('</script>'));
  assert.ok(json.includes('\\u003c/script>'));
  assert.ok(json.includes('\\u2028') && json.includes('\\u2029'));
  assert.deepStrictEqual(JSON.parse(json), { text: '</script><script>alert(1)</script>  ' });
});

test('normalizePlan accepts the same key names as the template data model', () => {
  const plan = normalizePlan({
    title: 'T',
    module: 'M',
    goal: 'G',
    context: 'C',
    patternCore: 'PC',
    patternBusiness: 'PB',
    patternSpecific: 'PS',
    patternOverrides: 'PO'
  });
  assert.strictEqual(plan.title, 'T');
  assert.strictEqual(plan.module, 'M');
  assert.strictEqual(plan.goal, 'G');
  assert.strictEqual(plan.context, 'C');
  assert.strictEqual(plan.patternCore, 'PC');
  assert.strictEqual(plan.patternBusiness, 'PB');
  assert.strictEqual(plan.patternSpecific, 'PS');
  assert.strictEqual(plan.patternOverrides, 'PO');
});

test('normalizePlan fills string defaults for missing top-level keys', () => {
  const plan = normalizePlan({});
  assert.strictEqual(plan.title, '');
  assert.strictEqual(plan.module, '');
  assert.strictEqual(plan.goal, '');
  assert.strictEqual(plan.context, '');
  assert.strictEqual(plan.patternSpecific, '');
  assert.strictEqual(plan.patternOverrides, '');
});

test('normalizePlan falls back to standard pattern defaults when omitted', () => {
  // Ensures the same defaults the template ships, so an injected plan that
  // forgets the pattern fields still renders the conventional layered +
  // transaction-script scaffolding.
  const plan = normalizePlan({});
  assert.strictEqual(plan.patternCore, 'Layered (Controller -> Service -> Repository)');
  assert.strictEqual(plan.patternBusiness, 'Transaction Script');
});

test('normalizePlan fills empty arrays for missing section arrays', () => {
  const plan = normalizePlan({});
  for (const section of SECTIONS) {
    assert.deepStrictEqual(plan[section], [], `${section} should default to []`);
  }
});

test('normalizePlan fills per-field defaults for sparse section items', () => {
  const plan = normalizePlan({
    files: [{ id: 'f-1' }],
    logicSteps: [{ id: 'l-1' }],
    contracts: [{ id: 'c-1' }],
    edgeCases: [{ id: 'e-1' }],
    testScenarios: [{ id: 't-1' }]
  });
  // Identity preserved
  assert.strictEqual(plan.files[0].id, 'f-1');
  assert.strictEqual(plan.logicSteps[0].id, 'l-1');
  // Defaults applied
  assert.strictEqual(plan.files[0].action, 'create');
  assert.strictEqual(plan.files[0].path, '');
  assert.strictEqual(plan.files[0].description, '');
  assert.strictEqual(plan.files[0].pseudoCode, '');
  assert.strictEqual(plan.contracts[0].name, '');
  assert.strictEqual(plan.contracts[0].inputs, '');
  assert.strictEqual(plan.testScenarios[0].target, '');
  assert.strictEqual(plan.edgeCases[0].condition, '');
  assert.strictEqual(plan.edgeCases[0].handling, '');
});

test('normalizePlan coerces `order` to Number so the sort works', () => {
  const plan = normalizePlan({
    files: [{ id: 'a', order: '3' }, { id: 'b', order: '1' }]
  });
  assert.strictEqual(plan.files[0].order, 3);
  assert.strictEqual(plan.files[1].order, 1);
  assert.strictEqual(typeof plan.files[0].order, 'number');
});

test('normalizePlan preserves full content of every section type', () => {
  const plan = normalizePlan(sampleConfig());
  assert.strictEqual(plan.files.length, 2);
  assert.strictEqual(plan.files[0].action, 'create');
  assert.strictEqual(plan.files[1].action, 'update');
  assert.strictEqual(plan.logicSteps[0].step, 'Validate credentials');
  assert.strictEqual(plan.contracts[0].name, 'POST /api/v2/verify-2fa');
  assert.strictEqual(plan.edgeCases[0].handling, 'Return 401 with reason "2fa_required".');
  assert.strictEqual(plan.testScenarios[1].scenario, 'Returns 401 and increments failed_2fa counter.');
});

test('normalizePlan ignores non-array sections (defensive: bad input)', () => {
  const plan = normalizePlan({ files: 'not-an-array', logicSteps: null });
  assert.deepStrictEqual(plan.files, []);
  assert.deepStrictEqual(plan.logicSteps, []);
});

test('injectContent fills the feature title and leaves no unreplaced placeholders', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  assert.ok(html.includes('Feature Implementation Plan – Add two-factor authentication'));
  assert.ok(html.includes('⚙️ Feature Implementation Plan – Add two-factor authentication'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent defaults the feature title to "Untitled" when omitted', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), {});
  assert.ok(html.includes('Feature Implementation Plan – Untitled'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent embeds the plan as valid, parseable JSON', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  const match = html.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
  assert.ok(match, 'INITIAL_DATA assignment not found');
  const parsed = JSON.parse(match[1]);
  assert.strictEqual(parsed.title, 'Add two-factor authentication');
  assert.strictEqual(parsed.module, 'User Service');
  assert.strictEqual(parsed.goal.length > 0, true);
  assert.strictEqual(parsed.patternCore, 'Layered (Controller -> Service -> Repository)');
  assert.strictEqual(parsed.files[0].path, 'src/Security/TotpService.php');
  assert.strictEqual(parsed.files[1].action, 'update');
  assert.strictEqual(parsed.logicSteps[0].step, 'Validate credentials');
  assert.strictEqual(parsed.testScenarios[1].scenario, 'Returns 401 and increments failed_2fa counter.');
});

test('injectContent escapes the feature title but keeps the JSON payload intact', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'A <b>bold</b> "Plan"' }));
  assert.ok(html.includes('A &lt;b&gt;bold&lt;/b&gt; &quot;Plan&quot;'));
});

test('injectContent tolerates a config with only a title', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), { title: 'Bare' });
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
  const match = html.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
  const parsed = JSON.parse(match[1]);
  assert.strictEqual(parsed.title, 'Bare');
  for (const section of SECTIONS) {
    assert.deepStrictEqual(parsed[section], [], `${section} should default to []`);
  }
});

test('injectContent keeps dollar-sign patterns in the title literal', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'price = $& + $1' }));
  assert.ok(html.includes('price = $&amp; + $1'));
});

test('injectContent emits every section from the sample config', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  for (const marker of [
    'Add two-factor authentication',                  // title
    'User Service',                                    // module
    'TotpService.php', 'AuthService.php',              // files
    'TOTP enrollment', 'Wire TOTP',                    // file descriptions
    'POST /api/v2/verify-2fa',                         // contract
    'User has 2FA enabled',                            // edge case
    'TotpService::enroll()',                           // test target
  ]) {
    assert.ok(html.includes(marker), `expected injection output to contain ${JSON.stringify(marker)}`);
  }
});

test('ITEM_FIELD_DEFAULTS only defines known sections', () => {
  assert.deepStrictEqual(
    Object.keys(ITEM_FIELD_DEFAULTS).sort(),
    [...SECTIONS].sort()
  );
});

test('end-to-end: inject + write produces a complete HTML file with parseable JSON', () => {
  const fs = require('node:fs');
  const os = require('node:os');

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-test-'));
  const jsonPath = path.join(tmpDir, 'featurePlan.json');
  const htmlPath = path.join(tmpDir, 'featurePlan.html');

  try {
    fs.writeFileSync(jsonPath, JSON.stringify(sampleConfig()));
    const config = JSON.parse(fs.readFileSync(jsonPath, 'utf-8'));
    const html = injectContent(loadTemplate(TEMPLATE_PATH), config);
    fs.writeFileSync(htmlPath, html);

    // Read the on-disk file back and verify the contract the CLI promises.
    const written = fs.readFileSync(htmlPath, 'utf-8');
    assert.ok(
      written.includes('Feature Implementation Plan – Add two-factor authentication'),
      'feature title rendered into <title>/<h1>'
    );
    assert.strictEqual(
      written.match(/{{[A-Z0-9_]+}}/g),
      null,
      'no unreplaced placeholders left in written file'
    );
    const match = written.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
    assert.ok(match, 'INITIAL_DATA assignment present in written file');
    const parsed = JSON.parse(match[1]);
    assert.strictEqual(parsed.title, 'Add two-factor authentication');
    assert.strictEqual(parsed.files.length, 2);
    assert.strictEqual(parsed.testScenarios.length, 2);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('CLI main() executes node featurePlan-inject.js end-to-end', () => {
  const { execFileSync } = require('node:child_process');
  const fs = require('node:fs');
  const os = require('node:os');

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-cli-'));
  const jsonPath = path.join(tmpDir, 'plan.json');
  const htmlPath = path.join(tmpDir, 'plan.html');

  try {
    fs.writeFileSync(jsonPath, JSON.stringify(sampleConfig()));

    // Run the actual CLI entrypoint against the real on-disk script. This
    // exercises argument parsing, config-key normalization, template
    // loading, and fs.writeFileSync in one shot — anything `main()` does
    // beyond injectContent() is only covered here.
    const scriptPath = path.join(__dirname, 'featurePlan-inject.js');
    execFileSync(
      process.execPath,
      [scriptPath, jsonPath, htmlPath],
      { stdio: 'pipe' }
    );

    const written = fs.readFileSync(htmlPath, 'utf-8');
    assert.ok(
      written.includes('Feature Implementation Plan – Add two-factor authentication'),
      'CLI produced a file with the injected title'
    );
    assert.strictEqual(
      written.match(/{{[A-Z0-9_]+}}/g),
      null,
      'no unreplaced placeholders after CLI run'
    );
    const match = written.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
    const parsed = JSON.parse(match[1]);
    assert.strictEqual(parsed.title, 'Add two-factor authentication');
    assert.strictEqual(parsed.files[0].path, 'src/Security/TotpService.php');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('CLI main() rejects a missing-args invocation with a usage message', () => {
  const { execFileSync } = require('node:child_process');

  const scriptPath = path.join(__dirname, 'featurePlan-inject.js');
  let stderr = '';
  let exitCode = 0;
  try {
    execFileSync(process.execPath, [scriptPath], { stdio: 'pipe' });
  } catch (err) {
    stderr = err.stderr ? err.stderr.toString() : '';
    exitCode = err.status;
  }

  assert.strictEqual(exitCode, 1, 'CLI exits non-zero on missing args');
  assert.ok(
    /Usage:.*featurePlan-inject\.js/.test(stderr),
    `expected usage message on stderr, got: ${JSON.stringify(stderr)}`
  );
});
