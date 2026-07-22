#!/usr/bin/env node
// Unit tests for featurePlan-inject.js. Run with: node --test agents/skills/feature-plan/featurePlan-inject.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const {
  escapeHtml,
  toScriptJson,
  deriveFolderStructure,
  extractInitialData,
  mergePlans,
  normalizePlan,
  injectContent,
  loadTemplate,
  createPatch,
  createAddPatch,
  SECTIONS,
  ITEM_FIELD_DEFAULTS
} = require('./featurePlan-inject.js');

const TEMPLATE_PATH = path.join(__dirname, 'featurePlan-template.html');

function sampleConfig(overrides = {}) {
  return {
    title: 'Add two-factor authentication',
    overview: 'User asked: "add 2FA to login". I understand this as a TOTP second factor verified at login, with enrollment from the profile page. Existing User.php, AuthService.php, and a users table with columns id, email, password_hash.',
    architecture: 'Layered flow, one new service:\n\n  LoginController -> AuthService -> TotpService [NEW]\n\nTOTP logic is isolated in TotpService; no separate Repository for OTP — reuse UserRepository.',
    folderStructure: 'src/\n├── Auth/\n│   └── AuthService.php    [UPDATE]\n└── Security/\n    └── TotpService.php    [CREATE]',
    openQuestions: [
      { id: 'q1', question: 'Mandatory enrollment at next login, or opt-in?', options: 'A) Mandatory (recommended)\nB) Opt-in from profile', decision: '' }
    ],
    acceptanceCriteria: [
      { id: 'a1', criterion: 'Login without a code is rejected with 2fa_required when 2FA is enabled', testCase: 'Integration test on POST /login.' }
    ],
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
    overview: 'O',
    architecture: 'A',
    folderStructure: 'F'
  });
  assert.strictEqual(plan.title, 'T');
  assert.strictEqual(plan.overview, 'O');
  assert.strictEqual(plan.architecture, 'A');
  assert.strictEqual(plan.folderStructure, 'F');
});

test('normalizePlan fills string defaults for missing top-level keys', () => {
  const plan = normalizePlan({});
  assert.strictEqual(plan.title, '');
  assert.strictEqual(plan.overview, '');
  assert.strictEqual(plan.architecture, '');
  assert.strictEqual(plan.folderStructure, '');
});

test('normalizePlan fills empty arrays for missing section arrays', () => {
  const plan = normalizePlan({});
  for (const section of SECTIONS) {
    assert.deepStrictEqual(plan[section], [], `${section} should default to []`);
  }
});

test('normalizePlan fills per-field defaults for sparse section items', () => {
  const plan = normalizePlan({
    acceptanceCriteria: [{ id: 'a-1' }],
    files: [{ id: 'f-1' }],
    logicSteps: [{ id: 'l-1' }],
    contracts: [{ id: 'c-1' }],
    edgeCases: [{ id: 'e-1' }]
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
  assert.strictEqual(plan.edgeCases[0].condition, '');
  assert.strictEqual(plan.edgeCases[0].handling, '');
  assert.strictEqual(plan.acceptanceCriteria[0].id, 'a-1');
  assert.strictEqual(plan.acceptanceCriteria[0].criterion, '');
  assert.strictEqual(plan.acceptanceCriteria[0].testCase, '');
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
  assert.strictEqual(plan.overview.startsWith('User asked:'), true);
  assert.strictEqual(plan.architecture.includes('TotpService [NEW]'), true);
  assert.strictEqual(plan.folderStructure.includes('[CREATE]'), true);
  assert.strictEqual(plan.acceptanceCriteria[0].testCase, 'Integration test on POST /login.');
  assert.strictEqual(plan.files.length, 2);
  assert.strictEqual(plan.files[0].action, 'create');
  assert.strictEqual(plan.files[1].action, 'update');
  assert.strictEqual(plan.logicSteps[0].step, 'Validate credentials');
  assert.strictEqual(plan.contracts[0].name, 'POST /api/v2/verify-2fa');
  assert.strictEqual(plan.edgeCases[0].handling, 'Return 401 with reason "2fa_required".');
});

test('normalizePlan fills openQuestions defaults and preserves content', () => {
  const plan = normalizePlan({ openQuestions: [{ id: 'q-1' }] });
  assert.strictEqual(plan.openQuestions[0].id, 'q-1');
  assert.strictEqual(plan.openQuestions[0].question, '');
  assert.strictEqual(plan.openQuestions[0].options, '');
  assert.strictEqual(plan.openQuestions[0].decision, '');
  const full = normalizePlan(sampleConfig());
  assert.strictEqual(full.openQuestions[0].question, 'Mandatory enrollment at next login, or opt-in?');
  assert.strictEqual(full.openQuestions[0].decision, '');
});

test('deriveFolderStructure builds a tree with action markers from files[]', () => {
  const tree = deriveFolderStructure([
    { action: 'update', path: 'src/Auth/AuthService.php' },
    { action: 'create', path: 'src/Security/TotpService.php' }
  ]);
  assert.ok(tree.includes('src/') || tree.includes('src'), 'root directory rendered');
  assert.ok(tree.includes('AuthService.php    [UPDATE]'));
  assert.ok(tree.includes('TotpService.php    [CREATE]'));
  assert.ok(tree.includes('├── ') && tree.includes('└── '), 'ASCII branches rendered');
});

test('deriveFolderStructure returns empty string for no usable paths', () => {
  assert.strictEqual(deriveFolderStructure([]), '');
  assert.strictEqual(deriveFolderStructure([{ action: 'create', path: '' }]), '');
  assert.strictEqual(deriveFolderStructure(undefined), '');
});

test('normalizePlan derives folderStructure from files when omitted', () => {
  const config = sampleConfig();
  delete config.folderStructure;
  const plan = normalizePlan(config);
  assert.ok(plan.folderStructure.includes('AuthService.php    [UPDATE]'));
  assert.ok(plan.folderStructure.includes('TotpService.php    [CREATE]'));
});

test('normalizePlan keeps an explicitly supplied folderStructure', () => {
  const plan = normalizePlan(sampleConfig());
  assert.strictEqual(plan.folderStructure, sampleConfig().folderStructure);
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
  assert.strictEqual(parsed.overview.length > 0, true);
  assert.strictEqual(parsed.architecture.includes('TotpService [NEW]'), true);
  assert.strictEqual(parsed.files[0].path, 'src/Security/TotpService.php');
  assert.strictEqual(parsed.files[1].action, 'update');
  assert.strictEqual(parsed.logicSteps[0].step, 'Validate credentials');
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
    'enrollment from the profile page',                // overview
    'TotpService [NEW]',                               // architecture
    'TotpService.php', 'AuthService.php',              // files
    'TOTP enrollment', 'Wire TOTP',                    // file descriptions
    'POST /api/v2/verify-2fa',                         // contract
    'User has 2FA enabled',                            // edge case
    'rejected with 2fa_required',                      // acceptance criterion
    'Mandatory enrollment at next login',              // open question
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
    assert.strictEqual(parsed.acceptanceCriteria.length, 1);
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

test('extractInitialData round-trips the plan out of generated HTML', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  const extracted = extractInitialData(html);
  assert.strictEqual(extracted.title, 'Add two-factor authentication');
  assert.strictEqual(extracted.files.length, 2);
});

test('extractInitialData throws on HTML without the INITIAL_DATA anchor', () => {
  assert.throws(() => extractInitialData('<html><body>hand-edited</body></html>'),
    /No INITIAL_DATA found/);
});

test('mergePlans keeps existing item ids, applies same-id updates, appends new ones', () => {
  const existing = normalizePlan(sampleConfig());
  const merged = mergePlans(existing, {
    files: [
      { id: 'f1', description: 'TOTP service (revised)' },       // same-id update
      { id: 'f9', order: 3, action: 'create', path: 'src/new.php', description: 'brand new' }
    ]
  });
  assert.strictEqual(merged.files.length, 3);
  assert.strictEqual(merged.files[0].id, 'f1');
  assert.strictEqual(merged.files[0].description, 'TOTP service (revised)');
  assert.strictEqual(merged.files[0].path, 'src/Security/TotpService.php', 'untouched fields survive');
  assert.strictEqual(merged.files[2].id, 'f9');
  // Sections absent from the incoming config survive untouched.
  assert.strictEqual(merged.openQuestions.length, 1);
  assert.strictEqual(merged.edgeCases[0].id, 'e1');
});

test('mergePlans: incoming scalars win only when non-empty', () => {
  const existing = normalizePlan(sampleConfig());
  const merged = mergePlans(existing, { overview: 'Revised overview', title: '' });
  assert.strictEqual(merged.overview, 'Revised overview');
  assert.strictEqual(merged.title, 'Add two-factor authentication', 'empty incoming title keeps existing');
});

test('mergePlans re-derives folderStructure from the merged manifest', () => {
  const existing = normalizePlan(sampleConfig());
  const merged = normalizePlan(mergePlans(existing, {
    files: [{ id: 'f9', order: 3, action: 'create', path: 'src/Extra.php', description: 'x' }]
  }));
  assert.ok(merged.folderStructure.includes('Extra.php    [CREATE]'));
  assert.ok(merged.folderStructure.includes('TotpService.php    [CREATE]'));
});

test('CLI update-in-place: second run merges into the existing HTML', () => {
  const { execFileSync } = require('node:child_process');
  const fs = require('node:fs');
  const os = require('node:os');

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'featurePlan-merge-'));
  const jsonPath = path.join(tmpDir, 'plan.json');
  const htmlPath = path.join(tmpDir, 'plan.html');
  const scriptPath = path.join(__dirname, 'featurePlan-inject.js');

  try {
    fs.writeFileSync(jsonPath, JSON.stringify(sampleConfig()));
    const first = execFileSync(process.execPath, [scriptPath, jsonPath, htmlPath], { stdio: 'pipe' }).toString();
    assert.ok(first.includes('✓ Generated'), 'first run generates');

    // Second run: only a delta config — prior sections must survive.
    fs.writeFileSync(jsonPath, JSON.stringify({
      files: [{ id: 'f3', order: 3, action: 'create', path: 'src/Security/RecoveryCodes.php', description: 'recovery codes' }]
    }));
    const second = execFileSync(process.execPath, [scriptPath, jsonPath, htmlPath], { stdio: 'pipe' }).toString();
    assert.ok(second.includes('✓ Updated (merged)'), 'second run merges');

    const parsed = extractInitialData(fs.readFileSync(htmlPath, 'utf-8'));
    assert.strictEqual(parsed.title, 'Add two-factor authentication', 'title survives delta run');
    assert.strictEqual(parsed.files.length, 3);
    assert.strictEqual(parsed.openQuestions.length, 1, 'untouched sections survive');
    assert.ok(parsed.folderStructure.includes('RecoveryCodes.php    [CREATE]'), 'tree re-derived');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('createPatch generates a properly formatted patch operation', () => {
  const patch = createPatch('files', 'f-1', 'description', 'New description', 'update');
  assert.strictEqual(patch.type, 'patch');
  assert.strictEqual(patch.section, 'files');
  assert.strictEqual(patch.itemId, 'f-1');
  assert.strictEqual(patch.field, 'description');
  assert.strictEqual(patch.value, 'New description');
  assert.strictEqual(patch.action, 'update');
});

test('createPatch defaults action to "update"', () => {
  const patch = createPatch('files', 'f-1', 'path', 'src/NewFile.php');
  assert.strictEqual(patch.action, 'update');
});

test('createAddPatch generates an add operation', () => {
  const item = { criterion: 'New criterion', testCase: 'Manual test' };
  const patch = createAddPatch('acceptanceCriteria', item);
  assert.strictEqual(patch.type, 'patch');
  assert.strictEqual(patch.section, 'acceptanceCriteria');
  assert.strictEqual(patch.action, 'add');
  assert.deepStrictEqual(patch.item, item);
});
