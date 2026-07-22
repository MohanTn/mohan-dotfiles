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
 * See this folder's SKILL.md for the JSON schema.
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
// agents/skills/feature-plan/featurePlan-template.html — both describe the
// same per-section field schema, and adding or renaming a field requires
// changes in both places.
const ITEM_FIELD_DEFAULTS = {
  openQuestions:    { question: '', options: '', decision: '' },
  solutionApproach: { aspect: '', rationale: '' },
  acceptanceCriteria: { criterion: '', testCase: '' },
  files:            { order: 0, action: 'create', path: '', description: '', pseudoCode: '' },
  logicSteps:       { step: '', pseudo: '' },
  contracts:        { name: '', inputs: '', outputs: '' },
  edgeCases:        { condition: '', handling: '' }
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

// Scalar plan fields merged by mergePlans (folderStructure is excluded: it is
// re-derived from the merged files[] unless the incoming config overrides it).
const SCALAR_KEYS = ['title', 'overview', 'architecture'];

// Pulls the embedded plan back out of a previously generated output HTML.
// Throws when the anchor is missing or unparseable (hand-edited file) so the
// CLI can refuse to corrupt it instead of silently overwriting.
function extractInitialData(html) {
  const match = html.match(/const INITIAL_DATA = ([\s\S]*?);\n/);
  if (!match) {
    throw new Error('No INITIAL_DATA found — not a generated featurePlan HTML');
  }
  try {
    return JSON.parse(match[1]);
  } catch (e) {
    throw new Error(`INITIAL_DATA in existing HTML is not valid JSON: ${e.message}`);
  }
}

// Update-in-place merge: applies an incoming config on top of the plan already
// embedded in the output HTML. Existing items keep their id and position,
// same-id items take the incoming fields, unknown-id items append, and items
// absent from the incoming config survive — never a blind overwrite. Human
// browser edits are not in the file (they live in localStorage keyed by the
// title); the template reconciles them against the new seed on load.
function mergePlans(existing, incoming) {
  const merged = { ...existing };
  for (const key of SCALAR_KEYS) {
    if (incoming[key]) merged[key] = incoming[key];
  }
  // Let normalizePlan re-derive the tree from the merged manifest unless the
  // incoming config explicitly overrides it.
  merged.folderStructure = incoming.folderStructure || '';

  for (const section of SECTIONS) {
    const existingItems = Array.isArray(existing[section])
      ? existing[section].map(it => ({ ...it }))
      : [];
    const incomingItems = Array.isArray(incoming[section]) ? incoming[section] : [];
    for (const inc of incomingItems) {
      const target = inc && inc.id !== undefined
        ? existingItems.find(it => it.id === inc.id)
        : undefined;
      if (target) {
        Object.assign(target, inc);
      } else {
        existingItems.push({ ...inc });
      }
    }
    merged[section] = existingItems;
  }
  return merged;
}

function normalizePlan(config) {
  const normalized = {
    title:           config.title || '',
    overview:        config.overview || '',
    architecture:    config.architecture || '',
    folderStructure: config.folderStructure || ''
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
    console.error('  <input-json>    JSON with title, overview, architecture,');
    console.error('                  openQuestions, solutionApproach, acceptanceCriteria,');
    console.error('                  files, logicSteps, contracts, edgeCases');
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
    let config = JSON.parse(fs.readFileSync(inputJsonPath, 'utf-8'));
    // Update-in-place: an existing output HTML is merged into, not replaced.
    const updating = fs.existsSync(outputHtmlPath);
    if (updating) {
      const existing = extractInitialData(fs.readFileSync(outputHtmlPath, 'utf-8'));
      config = mergePlans(existing, config);
    }
    const template = loadTemplate(templatePath);
    const html = injectContent(template, config);
    fs.writeFileSync(outputHtmlPath, html, 'utf-8');
    console.log(updating ? `✓ Updated (merged): ${outputHtmlPath}` : `✓ Generated: ${outputHtmlPath}`);
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
  extractInitialData,
  mergePlans,
  normalizePlan,
  injectContent,
  loadTemplate,
  createPatch,
  createAddPatch,
  SECTIONS,
  SCALAR_KEYS,
  ITEM_FIELD_DEFAULTS
};
