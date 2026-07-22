#!/usr/bin/env node
/**
 * featurePlan-inject.js — Injects a feature implementation plan into the HTML template.
 *
 * The plan is a file-by-file, code-level plan for building a feature inside an
 * existing codebase: file change manifest (ordered by build sequence), core
 * business logic pseudo-code, function/API contracts, edge cases, and testing
 * strategy. All editing happens client-side in the template; this script's
 * only job is to seed the initial data so the human isn't starting from a
 * blank page.
 *
 * Usage: node featurePlan-inject.js <input-json> <output-html> [template-path]
 *
 * See claude/commands/featurePlan.md / copilot/skills/featurePlan/SKILL.md
 * for the JSON schema.
 */

const fs = require('fs');
const path = require('path');

function escapeHtml(text) {
  const map = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return String(text).replace(/[&<>"']/g, m => map[m]);
}

// Embeds a value as a JSON literal inside a <script> tag. Escapes characters
// that would otherwise close the tag early (</script>) or break older JS
// parsers that treat U+2028/U+2029 as line terminators inside string literals.
function toScriptJson(value) {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

function loadTemplate(templatePath) {
  if (!fs.existsSync(templatePath)) {
    throw new Error(`Template not found: ${templatePath}`);
  }
  return fs.readFileSync(templatePath, 'utf-8');
}

// String fields a section item accepts. Each entry maps a JSON key to its
// default value (empty for free text, the first option for selects).
//
// NOTE: This table MUST stay in sync with the bindAdd() inline defaults in
// agents/skills/featurePlan/featurePlan-template.html — both describe the
// same per-section field schema, and adding or renaming a field requires
// changes in both places.
const ITEM_FIELD_DEFAULTS = {
  openQuestions:    { question: '', options: '', decision: '' },
  solutionApproach: { aspect: '', rationale: '' },
  acceptanceCriteria: { criterion: '', verification: '' },
  files:            { order: 0, action: 'create', path: '', description: '', pseudoCode: '' },
  logicSteps:       { step: '', pseudo: '' },
  contracts:        { name: '', inputs: '', outputs: '' },
  edgeCases:        { condition: '', handling: '' },
  testScenarios:    { target: '', scenario: '' }
};

// Sections are top-level arrays in the config + the emptyData() template.
// Keeps normalizePlan a single understood loop instead of hand-rolling each.
const SECTIONS = Object.keys(ITEM_FIELD_DEFAULTS);

// Applies ITEM_FIELD_DEFAULTS to a single item, preserving its `id` and any
// unrecognized keys the caller added. Missing fields get the section default;
// present fields pass through unchanged. `order` is coerced to a Number so the
// template's numeric sort works on injected items too.
function normalizeItem(sectionKey, raw) {
  const defaults = ITEM_FIELD_DEFAULTS[sectionKey];
  const out = { ...defaults, ...(raw || {}) };
  if (raw && raw.id !== undefined) out.id = raw.id;
  if ('order' in (raw || {})) out.order = Number(raw.order) || 0;
  return out;
}

// Builds the "Resulting Folder Structure" ASCII tree from files[] so the AI
// never authors it by hand — the manifest is the single source of truth for
// which paths change. Returns '' when there are no usable paths.
function deriveFolderStructure(files) {
  const entries = (files || [])
    .filter(f => f && f.path)
    .sort((a, b) => a.path.localeCompare(b.path));
  if (entries.length === 0) return '';

  const root = { children: {} };
  for (const f of entries) {
    let node = root;
    const parts = f.path.split('/').filter(Boolean);
    parts.forEach((part, i) => {
      node.children[part] = node.children[part] || { children: {} };
      node = node.children[part];
      if (i === parts.length - 1) {
        node.marker = `[${String(f.action || 'update').toUpperCase()}]`;
      }
    });
  }

  const lines = [];
  const walk = (node, prefix) => {
    const names = Object.keys(node.children);
    names.forEach((name, i) => {
      const child = node.children[name];
      const isLast = i === names.length - 1;
      const isDir = Object.keys(child.children).length > 0;
      const label = name + (isDir && !child.marker ? '/' : '');
      lines.push(prefix + (isLast ? '└── ' : '├── ') + label + (child.marker ? `    ${child.marker}` : ''));
      walk(child, prefix + (isLast ? '    ' : '│   '));
    });
  };
  walk(root, '');
  return lines.join('\n');
}

function normalizePlan(config) {
  const normalized = {
    title:            config.title || '',
    module:           config.module || '',
    intent:           config.intent || '',
    goal:             config.goal || '',
    context:          config.context || '',
    folderStructure:  config.folderStructure || '',
    patternCore:      config.patternCore || 'Layered (Controller -> Service -> Repository)',
    patternBusiness:  config.patternBusiness || 'Transaction Script',
    patternSpecific:  config.patternSpecific || '',
    patternOverrides: config.patternOverrides || ''
  };

  for (const section of SECTIONS) {
    const items = config[section];
    normalized[section] = Array.isArray(items)
      ? items.map(it => normalizeItem(section, it))
      : [];
  }

  // The manifest is the single source of truth for touched paths; derive the
  // tree unless the config explicitly overrides it.
  if (!normalized.folderStructure) {
    normalized.folderStructure = deriveFolderStructure(normalized.files);
  }

  return normalized;
}

function injectContent(template, config) {
  let html = template;

  // Replacement values go through a function so `$&`, `$'`, `$1` etc. in the
  // content are kept literal instead of being expanded by String.replace.
  const put = (pattern, value) => {
    html = html.replace(pattern, () => value);
  };

  put(/{{FEATURE_TITLE}}/g, escapeHtml(config.title || 'Untitled'));
  put(/{{INITIAL_DATA_JSON}}/, toScriptJson(normalizePlan(config)));

  return html;
}

function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.error('Usage: node featurePlan-inject.js <input-json> <output-html> [template-path]');
    console.error('');
    console.error('Arguments:');
    console.error('  <input-json>    JSON with title, module, intent, goal, context,');
    console.error('                  patternCore, patternBusiness, patternSpecific,');
    console.error('                  patternOverrides, openQuestions, solutionApproach,');
    console.error('                  acceptanceCriteria, files, logicSteps, contracts,');
    console.error('                  edgeCases, testScenarios');
    console.error('                  (folderStructure is derived from files[] unless supplied)');
    console.error('  <output-html>   Path to write the final feature plan document');
    console.error('  [template-path] HTML template (default: featurePlan-template.html next to this script)');
    process.exit(1);
  }

  const inputJsonPath = args[0];
  const outputHtmlPath = args[1];
  const templatePath = args[2] || path.join(__dirname, 'featurePlan-template.html');

  try {
    if (!fs.existsSync(inputJsonPath)) {
      throw new Error(`Input JSON not found: ${inputJsonPath}`);
    }
    const config = JSON.parse(fs.readFileSync(inputJsonPath, 'utf-8'));
    const template = loadTemplate(templatePath);
    const html = injectContent(template, config);
    fs.writeFileSync(outputHtmlPath, html, 'utf-8');
    console.log(`✓ Generated: ${outputHtmlPath}`);
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

// Utility functions for harness/socket integration

// Build a patch operation for a specific field in a section item
function createPatch(section, itemId, field, value, action = 'update') {
  return {
    type: 'patch',
    section,
    itemId,
    field,
    value,
    action
  };
}

// Utility to add an item to a section
function createAddPatch(section, item) {
  return {
    type: 'patch',
    section,
    action: 'add',
    item
  };
}

module.exports = {
  escapeHtml,
  toScriptJson,
  deriveFolderStructure,
  normalizePlan,
  injectContent,
  loadTemplate,
  createPatch,
  createAddPatch,
  SECTIONS,
  ITEM_FIELD_DEFAULTS
};
