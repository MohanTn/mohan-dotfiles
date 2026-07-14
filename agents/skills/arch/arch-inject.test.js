#!/usr/bin/env node
// Unit tests for arch-inject.js. Run with: node --test agents/skills/arch/arch-inject.test.js

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
} = require('./arch-inject.js');

const TEMPLATE_PATH = path.join(__dirname, 'arch-template.html');

function sampleConfig(overrides = {}) {
  return {
    title: 'E-commerce Platform',
    description: 'Multi-tenant storefront with checkout, payments, and fulfilment.',
    context: 'Replaces the legacy monolith with a service-oriented platform.',
    actors: [
      { id: 'a1', name: 'Customer', type: 'User', description: 'Browses and checks out' },
      { id: 'a2', name: 'Payment Gateway', type: 'External System', description: 'Stripe' }
    ],
    containers: [
      { id: 'c1', name: 'Storefront API', tech: 'Node.js', responsibilities: 'Product, cart, checkout', dataStores: 'ProductDB' }
    ],
    integrations: [
      { id: 'i1', name: 'Checkout sync', from: 'Storefront', to: 'Payment Gateway', protocol: 'REST', sync: 'Sync', description: 'create charge' }
    ],
    entities: [
      { id: 'e1', name: 'Order', attributes: 'id, userId, total', relationships: 'belongs to User', storage: 'PostgreSQL' }
    ],
    adrs: [
      { id: 'd1', name: 'Use PostgreSQL', context: 'Need transactional guarantees', decision: 'PostgreSQL 16', rationale: 'Mature, ACID', tradeoffs: 'Operational overhead', status: 'Accepted' }
    ],
    qualities: [
      { id: 'q1', name: 'Availability', target: '99.95%', measurement: 'Prometheus uptime', details: 'Multi-AZ' }
    ],
    security: [
      { id: 's1', name: 'OAuth2 for APIs', detail: 'JWT with rotating keys' }
    ],
    deployment: [
      { id: 'dp1', name: 'Cloud', detail: 'AWS, multi-region primary/secondary' }
    ],
    risks: [
      { id: 'r1', name: 'Payment gateway downtime', impact: 'High', probability: 'Low', mitigation: 'Queue + retry with circuit breaker' }
    ],
    roadmap: [
      { id: 'p1', name: 'Phase 1: MVP', features: 'Storefront + payments', timeline: 'Q3 2026' }
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

test('normalizePlan maps friendly top-level keys to template field names', () => {
  const plan = normalizePlan({
    title: 'T',
    description: 'D',
    context: 'C'
  });
  assert.strictEqual(plan.projectName, 'T');
  assert.strictEqual(plan.projectDesc, 'D');
  assert.strictEqual(plan.projectContext, 'C');
});

test('normalizePlan fills empty defaults for missing top-level keys', () => {
  const plan = normalizePlan({});
  assert.strictEqual(plan.projectName, '');
  assert.strictEqual(plan.projectDesc, '');
  assert.strictEqual(plan.projectContext, '');
});

test('normalizePlan fills empty arrays for missing section arrays', () => {
  const plan = normalizePlan({});
  for (const section of SECTIONS) {
    assert.deepStrictEqual(plan[section], [], `${section} should default to []`);
  }
});

test('normalizePlan fills per-field defaults for sparse section items', () => {
  const plan = normalizePlan({
    actors: [{ id: 'a-1' }],
    containers: [{ name: 'Just a name' }],
    integrations: [{ id: 'i-1' }],
    adrs: [{ id: 'd-1' }]
  });
  // Identity preserved
  assert.strictEqual(plan.actors[0].id, 'a-1');
  // Defaults applied
  assert.strictEqual(plan.actors[0].type, 'User');
  assert.strictEqual(plan.actors[0].description, '');
  assert.strictEqual(plan.containers[0].tech, '');
  assert.strictEqual(plan.containers[0].responsibilities, '');
  // Name preserved when provided
  assert.strictEqual(plan.containers[0].name, 'Just a name');
  // ADR defaults
  assert.strictEqual(plan.adrs[0].status, 'Proposed');
  assert.strictEqual(plan.adrs[0].rationale, '');
  // Integration defaults
  assert.strictEqual(plan.integrations[0].protocol, 'REST');
  assert.strictEqual(plan.integrations[0].sync, 'Sync');
});

test('normalizePlan preserves full content of every section type', () => {
  const plan = normalizePlan(sampleConfig());
  assert.strictEqual(plan.actors.length, 2);
  assert.strictEqual(plan.actors[1].type, 'External System');
  assert.strictEqual(plan.containers[0].tech, 'Node.js');
  assert.strictEqual(plan.integrations[0].from, 'Storefront');
  assert.strictEqual(plan.entities[0].storage, 'PostgreSQL');
  assert.strictEqual(plan.adrs[0].status, 'Accepted');
  assert.strictEqual(plan.qualities[0].target, '99.95%');
  assert.strictEqual(plan.security[0].detail, 'JWT with rotating keys');
  assert.strictEqual(plan.deployment[0].detail, 'AWS, multi-region primary/secondary');
  assert.strictEqual(plan.risks[0].impact, 'High');
  assert.strictEqual(plan.roadmap[0].timeline, 'Q3 2026');
});

test('normalizePlan ignored non-array sections (defensive: bad input)', () => {
  const plan = normalizePlan({ actors: 'not-an-array', containers: null });
  assert.deepStrictEqual(plan.actors, []);
  assert.deepStrictEqual(plan.containers, []);
});

test('injectContent fills the project title and leaves no unreplaced placeholders', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  assert.ok(html.includes('Architecture &amp; Solution Plan – E-commerce Platform'));
  assert.ok(html.includes('🏛️ Architecture &amp; Solution Plan – E-commerce Platform'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent defaults the project title to "Untitled" when omitted', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), {});
  assert.ok(html.includes('Architecture &amp; Solution Plan – Untitled'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent embeds the plan as valid, parseable JSON', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  const match = html.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
  assert.ok(match, 'INITIAL_DATA assignment not found');
  const parsed = JSON.parse(match[1]);
  assert.strictEqual(parsed.projectName, 'E-commerce Platform');
  assert.strictEqual(parsed.projectDesc, 'Multi-tenant storefront with checkout, payments, and fulfilment.');
  assert.strictEqual(parsed.projectContext, 'Replaces the legacy monolith with a service-oriented platform.');
  assert.strictEqual(parsed.actors[0].name, 'Customer');
  assert.strictEqual(parsed.actors[1].type, 'External System');
  assert.strictEqual(parsed.containers[0].tech, 'Node.js');
  assert.strictEqual(parsed.adrs[0].status, 'Accepted');
  assert.strictEqual(parsed.roadmap[0].timeline, 'Q3 2026');
});

test('injectContent escapes the project title but keeps the JSON payload intact', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'A <b>bold</b> "Plan"' }));
  assert.ok(html.includes('A &lt;b&gt;bold&lt;/b&gt; &quot;Plan&quot;'));
});

test('injectContent tolerates a config with only a title', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), { title: 'Bare' });
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
  const match = html.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
  const parsed = JSON.parse(match[1]);
  assert.strictEqual(parsed.projectName, 'Bare');
  assert.strictEqual(parsed.projectDesc, '');
  assert.strictEqual(parsed.projectContext, '');
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
    'Customer', 'Payment Gateway',                    // actors
    'Storefront API', 'Node.js',                      // containers
    'Checkout sync', 'Payment Gateway', 'REST', 'Sync', // integrations
    'Order', 'PostgreSQL',                            // entities
    'Use PostgreSQL', 'Accepted',                     // adrs
    'Availability', '99.95%',                         // qualities
    'OAuth2 for APIs',                                // security
    'AWS, multi-region',                              // deployment
    'Payment gateway downtime', 'circuit breaker',    // risks
    'Phase 1: MVP', 'Q3 2026'                         // roadmap
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
  const path = require('node:path');

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'arch-test-'));
  const jsonPath = path.join(tmpDir, 'arch.json');
  const htmlPath = path.join(tmpDir, 'arch.html');

  try {
    fs.writeFileSync(jsonPath, JSON.stringify(sampleConfig()));
    const config = JSON.parse(fs.readFileSync(jsonPath, 'utf-8'));
    const html = injectContent(loadTemplate(TEMPLATE_PATH), config);
    fs.writeFileSync(htmlPath, html);

    // Read the on-disk file back and verify the contract the CLI promises.
    const written = fs.readFileSync(htmlPath, 'utf-8');
    assert.ok(
      written.includes('Architecture &amp; Solution Plan – E-commerce Platform'),
      'project title rendered into <title>/<h1>'
    );
    assert.strictEqual(
      written.match(/{{[A-Z0-9_]+}}/g),
      null,
      'no unreplaced placeholders left in written file'
    );
    const match = written.match(/const INITIAL_DATA = ([\s\S]*?);\n\s*<\/script>/);
    assert.ok(match, 'INITIAL_DATA assignment present in written file');
    const parsed = JSON.parse(match[1]);
    assert.strictEqual(parsed.projectName, 'E-commerce Platform');
    assert.strictEqual(parsed.actors.length, 2);
    assert.strictEqual(parsed.roadmap[0].timeline, 'Q3 2026');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
