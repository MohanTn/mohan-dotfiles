#!/usr/bin/env node
/**
 * arch-inject.js — Injects a feature plan into the HTML template.
 *
 * The plan is a simple decision tool: topics/areas, each with options carrying
 * pros/cons for the human to pick between, plus a technical-details table and
 * counts. All interaction (selecting options, editing rows, exporting) happens
 * client-side in the template; this script's only job is to seed the initial
 * data so the human isn't starting from a blank page.
 *
 * Usage: node arch-inject.js <input-json> <output-html> [template-path]
 *
 * See claude/commands/arch.md / copilot/skills/arch/SKILL.md for the JSON schema.
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

function normalizePlan(config) {
  return {
    prompt: config.prompt || '',
    topics: Array.isArray(config.topics) ? config.topics.map(t => ({
      id: t.id,
      name: t.name || '',
      questions: Array.isArray(t.questions) ? t.questions : [],
      options: Array.isArray(t.options) ? t.options.map(o => ({
        id: o.id,
        name: o.name || '',
        pros: o.pros || '',
        cons: o.cons || ''
      })) : [],
      selectedOptionId: t.selectedOptionId || null
    })) : [],
    techRows: Array.isArray(config.techRows) ? config.techRows.map(r => ({
      id: r.id,
      action: r.action || '',
      file: r.file || '',
      comment: r.comment || ''
    })) : [],
    counts: {
      create: Number(config.counts && config.counts.create) || 0,
      update: Number(config.counts && config.counts.update) || 0,
      unit: Number(config.counts && config.counts.unit) || 0,
      integration: Number(config.counts && config.counts.integration) || 0
    }
  };
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
    console.error('Usage: node arch-inject.js <input-json> <output-html> [template-path]');
    console.error('');
    console.error('Arguments:');
    console.error('  <input-json>    JSON with title, prompt, topics, techRows, counts');
    console.error('  <output-html>   Path to write the final feature plan document');
    console.error('  [template-path] HTML template (default: arch-template.html next to this script)');
    process.exit(1);
  }

  const inputJsonPath = args[0];
  const outputHtmlPath = args[1];
  const templatePath = args[2] || path.join(__dirname, 'arch-template.html');

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

module.exports = {
  escapeHtml,
  toScriptJson,
  normalizePlan,
  injectContent,
  loadTemplate
};
