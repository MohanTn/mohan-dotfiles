#!/usr/bin/env node
/**
 * arch-inject.js — Template injection tool for architecture documents
 *
 * Usage:
 *   node arch-inject.js <input-json> <output-html> [template-path]
 *
 * Input JSON format:
 *   {
 *     "title": "How Does This Repo Work",
 *     "summary": "Reproducible machine setup as a Nix flake...",
 *     "stack": "Nix · Bash · Home Manager",
 *     "status": "DRAFT",
 *     "statusClass": "draft",
 *     "version": "v1",
 *     "lastUpdated": "2026-07-11",
 *     "authorModel": "Claude Haiku 4.5",
 *     "revisionLog": [
 *       { "version": "v1", "date": "2026-07-11", "summary": "Initial draft...", "drivenaBy": "First generation" }
 *     ],
 *     "sections": {
 *       "0": "<tr><td>...</td></tr>...",
 *       "1": "<div class='card'>...</div>...",
 *       ... (sections 2-10)
 *     }
 *   }
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
  return text.replace(/[&<>"']/g, m => map[m]);
}

function loadTemplate(templatePath) {
  if (!fs.existsSync(templatePath)) {
    throw new Error(`Template not found: ${templatePath}`);
  }
  return fs.readFileSync(templatePath, 'utf-8');
}

function buildRevisionLogHtml(entries) {
  return entries
    .map(entry => `<tr><td>${escapeHtml(entry.version)}</td><td>${escapeHtml(entry.date)}</td><td>${escapeHtml(entry.summary)}</td><td>${escapeHtml(entry.drivenBy)}</td></tr>`)
    .join('\n');
}

function injectContent(template, config) {
  let html = template;

  // Replacement values go through a function so `$&`, `$'`, `$1` etc. in the
  // content are kept literal instead of being expanded by String.replace.
  const put = (pattern, value) => {
    html = html.replace(pattern, () => value);
  };

  // Replace feature-level metadata
  put(/{{FEATURE_TITLE}}/g, escapeHtml(config.title));
  put(/{{FEATURE_SUMMARY}}/g, escapeHtml(config.summary));
  put(/{{STACK_BADGES}}/g, escapeHtml(config.stack));

  // Replace document control metadata
  put(/{{STATUS}}/g, escapeHtml(config.status));
  put(/{{STATUS_CLASS}}/g, escapeHtml(config.statusClass));
  put(/{{VERSION}}/g, escapeHtml(config.version));
  put(/{{LAST_UPDATED}}/g, escapeHtml(config.lastUpdated));
  put(/{{AUTHOR_MODEL}}/g, escapeHtml(config.authorModel));

  // Replace revision log (raw HTML, already escaped in input)
  put(/{{REVISION_LOG_ROWS}}/g, buildRevisionLogHtml(config.revisionLog));

  // Replace section content (raw HTML, assumed safe from input)
  for (let i = 0; i <= 10; i++) {
    const sectionContent = config.sections[`${i}`] || '';
    put(new RegExp(`{{SECTION_${i}_CONTENT}}`, 'g'), sectionContent);
  }

  return html;
}

function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.error('Usage: node arch-inject.js <input-json> <output-html> [template-path]');
    console.error('');
    console.error('Arguments:');
    console.error('  <input-json>   Path to JSON file with section content');
    console.error('  <output-html>  Path to write final HTML');
    console.error('  [template-path] Path to HTML template (default: arch-template.html next to this script)');
    process.exit(1);
  }

  const inputJsonPath = args[0];
  const outputHtmlPath = args[1];
  const templatePath = args[2] || path.join(__dirname, 'arch-template.html');

  try {
    // Load and parse input JSON
    if (!fs.existsSync(inputJsonPath)) {
      throw new Error(`Input JSON not found: ${inputJsonPath}`);
    }
    const config = JSON.parse(fs.readFileSync(inputJsonPath, 'utf-8'));

    // Load template
    const template = loadTemplate(templatePath);

    // Inject content
    const html = injectContent(template, config);

    // Write output
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

module.exports = { escapeHtml, buildRevisionLogHtml, injectContent, loadTemplate };
