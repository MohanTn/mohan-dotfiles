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
  loadTemplate
} = require('./arch-inject.js');

const TEMPLATE_PATH = path.join(__dirname, 'arch-template.html');

function sampleConfig(overrides = {}) {
  return {
    title: 'Sample Feature',
    prompt: 'I want to add retry logic to billing charges.',
    topics: [
      {
        id: 'topic-1',
        name: 'Retry strategy',
        questions: ['How many attempts before dunning?'],
        options: [
          { id: 'opt-1', name: 'Fixed backoff', pros: 'simple', cons: 'slow to adapt' },
          { id: 'opt-2', name: 'Exponential backoff', pros: 'adapts fast', cons: 'more complex' }
        ],
        selectedOptionId: 'opt-2'
      }
    ],
    techRows: [
      { id: 'row-1', action: 'create', file: 'src/billing/retry.js', comment: 'new retry scheduler' }
    ],
    counts: { create: 1, update: 2, unit: 3, integration: 1 },
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

test('normalizePlan fills defaults for missing fields', () => {
  const plan = normalizePlan({});
  assert.strictEqual(plan.prompt, '');
  assert.deepStrictEqual(plan.topics, []);
  assert.deepStrictEqual(plan.techRows, []);
  assert.deepStrictEqual(plan.counts, { create: 0, update: 0, unit: 0, integration: 0 });
});

test('normalizePlan preserves topic, option, and tech row fields', () => {
  const plan = normalizePlan(sampleConfig());
  assert.strictEqual(plan.topics[0].name, 'Retry strategy');
  assert.strictEqual(plan.topics[0].options[1].name, 'Exponential backoff');
  assert.strictEqual(plan.topics[0].selectedOptionId, 'opt-2');
  assert.strictEqual(plan.techRows[0].file, 'src/billing/retry.js');
  assert.strictEqual(plan.counts.unit, 3);
});

test('injectContent fills the title and leaves no unreplaced placeholders', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  assert.ok(html.includes('Feature Plan – Sample Feature'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent embeds the plan as valid, parseable JSON', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  const match = html.match(/const INITIAL_DATA = (.*);/);
  assert.ok(match, 'INITIAL_DATA assignment not found');
  const parsed = JSON.parse(match[1]);
  assert.strictEqual(parsed.prompt, 'I want to add retry logic to billing charges.');
  assert.strictEqual(parsed.topics[0].options[0].name, 'Fixed backoff');
});

test('injectContent escapes the title but keeps the JSON payload intact', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'A <b>bold</b> title' }));
  assert.ok(html.includes('A &lt;b&gt;bold&lt;/b&gt; title'));
});

test('injectContent tolerates a config with only a title', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), { title: 'Bare' });
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
  const match = html.match(/const INITIAL_DATA = (.*);/);
  assert.deepStrictEqual(JSON.parse(match[1]), { prompt: '', topics: [], techRows: [], counts: { create: 0, update: 0, unit: 0, integration: 0 } });
});

test('injectContent keeps dollar-sign patterns in the title literal', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'price = $& + $1' }));
  assert.ok(html.includes('price = $&amp; + $1'));
});
