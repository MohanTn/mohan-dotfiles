'use strict';

// Machine-readable view of the template library: languages, templates,
// per-language inject markers, and each template's data fields derived from
// the template source itself (the {{!-- Data: ... --}} header stays the
// human-facing doc; the required/optional split is computed from the
// placeholders so the two can never drift).

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

const MARKERS = {
  python: '# scaffold:inject',
  sh: '# scaffold:inject',
  default: '// scaffold:inject',
};

// Languages whose files are brace-delimited, i.e. where the "insert before
// the last }" inject fallback is structurally safe.
const BRACE_LANGS = new Set(['csharp', 'typescript', 'javascript', 'go']);

function markerFor(lang) {
  return Object.prototype.hasOwnProperty.call(MARKERS, lang) ? MARKERS[lang] : MARKERS.default;
}

function listLanguages() {
  return fs
    .readdirSync(ROOT, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => {
      try {
        return fs.readdirSync(path.join(ROOT, name)).some((f) => f.endsWith('.hbs'));
      } catch {
        return false;
      }
    })
    .sort();
}

function listTemplates(lang) {
  const dir = path.join(ROOT, lang);
  if (!fs.existsSync(dir)) {
    throw new Error(`Unknown language: ${lang}. Available: ${listLanguages().join(', ')}`);
  }
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.hbs'))
    .map((f) => f.replace(/\.hbs$/, ''))
    .sort();
}

function templateSource(lang, template) {
  const templatePath = path.join(ROOT, lang, `${template}.hbs`);
  if (!fs.existsSync(templatePath)) {
    const available = fs.existsSync(path.join(ROOT, lang)) ? listTemplates(lang) : [];
    throw new Error(
      `Template not found: ${templatePath}\nAvailable templates for "${lang}": ${available.join(', ') || '(none)'}`
    );
  }
  return fs.readFileSync(templatePath, 'utf8');
}

function templateMeta(lang, template) {
  const source = templateSource(lang, template);

  const commentMatch = source.match(/^\{\{!--\s*(Data:[\s\S]*?)--\}\}/);
  const dataComment = commentMatch ? commentMatch[1].trim() : '';

  const fields = [...new Set([...source.matchAll(/\{\{\{?(\w+)\}?\}\}/g)].map((m) => m[1]))].filter(
    (name) => name !== 'if' && name !== 'else'
  );
  const optional = [...new Set([...source.matchAll(/\{\{#if (\w+)\}\}/g)].map((m) => m[1]))];
  const required = fields.filter((f) => !optional.includes(f));

  return {
    lang,
    template,
    fields,
    required,
    optional,
    markerDefault: markerFor(lang),
    dataComment,
  };
}

module.exports = {
  ROOT,
  MARKERS,
  BRACE_LANGS,
  markerFor,
  listLanguages,
  listTemplates,
  templateSource,
  templateMeta,
};
