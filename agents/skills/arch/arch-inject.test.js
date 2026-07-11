#!/usr/bin/env node
// Unit tests for arch-inject.js. Run with: node --test claude/commands/arch-inject.test.js

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('path');
const { escapeHtml, buildRevisionLogHtml, injectContent, loadTemplate } = require('./arch-inject.js');

const TEMPLATE_PATH = path.join(__dirname, 'arch-template.html');

function sampleConfig(overrides = {}) {
  return {
    title: 'Sample Feature',
    summary: 'A test summary',
    stack: 'Node.js · React',
    status: 'DRAFT',
    statusClass: 'draft',
    version: 'v1',
    lastUpdated: '2026-07-11',
    authorModel: 'Claude Fable 5',
    revisionLog: [
      { version: 'v1', date: '2026-07-11', summary: 'Initial draft', drivenBy: 'First generation' }
    ],
    sections: {
      '1': '<div class="card"><p>Section one</p></div>',
      '3': '<div class="mermaid-card"><div class="mermaid">flowchart LR\n  A --> B</div></div>'
    },
    ...overrides
  };
}

test('escapeHtml escapes all HTML-sensitive characters', () => {
  assert.strictEqual(
    escapeHtml(`<b>"x" & 'y'</b>`),
    '&lt;b&gt;&quot;x&quot; &amp; &#039;y&#039;&lt;/b&gt;'
  );
});

test('buildRevisionLogHtml renders one escaped row per entry', () => {
  const rows = buildRevisionLogHtml([
    { version: 'v1', date: '2026-07-11', summary: 'Added <script>', drivenBy: 'User' },
    { version: 'v2', date: '2026-07-12', summary: 'Fix', drivenBy: 'Review' }
  ]);
  assert.strictEqual(rows.split('<tr>').length - 1, 2);
  assert.ok(rows.includes('&lt;script&gt;'));
  assert.ok(!rows.includes('<script>'));
});

test('injectContent fills metadata and leaves no unreplaced placeholders', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig());
  assert.ok(html.includes('Architecture — Sample Feature'));
  assert.ok(html.includes('status-banner draft'));
  assert.ok(html.includes('Section one'));
  const leftover = html.match(/{{[A-Z0-9_]+}}/g);
  assert.strictEqual(leftover, null, `unreplaced placeholders: ${leftover}`);
});

test('injectContent escapes metadata but injects section HTML raw', () => {
  const html = injectContent(loadTemplate(TEMPLATE_PATH), sampleConfig({ title: 'A <b>bold</b> title' }));
  assert.ok(html.includes('A &lt;b&gt;bold&lt;/b&gt; title'));
  assert.ok(html.includes('<div class="mermaid">flowchart LR'));
});

test('injectContent keeps dollar-sign patterns in section content literal', () => {
  const config = sampleConfig();
  config.sections['5'] = '<pre>price = `$&` + $1 + "$\'"</pre>';
  const html = injectContent(loadTemplate(TEMPLATE_PATH), config);
  assert.ok(html.includes('price = `$&` + $1 + "$\'"'));
});
