'use strict';

// Shared scaffolding core: the CLI (scaffold.js) and the MCP server
// (mcp-server.js) are both thin fronts over these functions, so hook-driven
// Bash use and MCP use behave identically. Every operation returns a
// structured result carrying the full numbered file content and the fillable
// line numbers — callers never need to re-read the file they just scaffolded.

const fs = require('fs');
const path = require('path');
// node_modules/ is gitignored, so the Nix-store copy of this directory ships
// without deps; nix/agents.nix populates this cache via npm ci at switch time.
function requireDep(name) {
  try {
    return require(name);
  } catch {
    return require(path.join(process.env.HOME || '', '.cache', 'boilerplats', 'node_modules', name));
  }
}
const Handlebars = requireDep('handlebars');
const meta = require('./template-meta');
const { findAnchor } = require('./anchor');

function render(lang, template, data) {
  const source = meta.templateSource(lang, template);
  return Handlebars.compile(source)(data);
}

function validateData(lang, template, data) {
  const { required } = meta.templateMeta(lang, template);
  const missing = required.filter((f) => {
    const v = (data || {})[f];
    return v === undefined || v === null || v === '';
  });
  if (missing.length > 0) {
    throw new Error(
      `Missing required data fields for ${lang}/${template}: ${missing.join(', ')}. ` +
        `Pass them via data, e.g. {"${missing[0]}": "..."}`
    );
  }
}

function writeNewFile(outPath, content, force) {
  if (fs.existsSync(outPath) && !force) {
    throw new Error(`File already exists: ${outPath} (use --inject or --force)`);
  }
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, content);
}

function indentOf(line) {
  const m = line.match(/^([ \t]+)/);
  return m ? m[1] : '';
}

// Templates are authored at column 0 with indentation relative to their own
// first line, so a rendered member can be dropped at any nesting depth: strip
// the block's common indent, then re-indent every line to match the marker's.
// Without this a class-level marker produced members whose bodies kept the
// template's absolute indentation (correct at one depth, broken at every other).
function reindent(content, indent) {
  const lines = content.replace(/\s+$/, '').split('\n');
  const widths = lines.filter((l) => l.trim()).map((l) => indentOf(l).length);
  const common = widths.length ? Math.min(...widths) : 0;
  return lines.map((l) => (l.trim() ? indent + l.slice(common) : ''));
}

// Low-level inject, shape-compatible with the pre-refactor scaffold.js export.
// allowBraceFallback is decided per language by scaffoldInject; the default
// (true) preserves the historical CLI behavior for direct callers.
function injectIntoFile(outPath, content, marker, { allowBraceFallback = true } = {}) {
  if (!fs.existsSync(outPath)) {
    throw new Error(`Cannot inject, file does not exist: ${outPath}`);
  }
  const lines = fs.readFileSync(outPath, 'utf8').split('\n');

  let index = lines.findIndex((l) => l.includes(marker));
  let fallback = false;

  if (index === -1) {
    if (!allowBraceFallback) {
      throw new Error(
        `Marker "${marker}" not found in: ${outPath}. Adopt the file first so later ` +
          `injections have a stable insertion point.`
      );
    }
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim().startsWith('}')) {
        index = i;
        break;
      }
    }
    if (index === -1) {
      throw new Error(
        `Marker "${marker}" not found and no "}" fallback point available in: ${outPath}`
      );
    }
    fallback = true;
  }

  const block = reindent(content, indentOf(lines[index]));
  // Keep one blank line on each side so repeated injections stay readable
  // instead of butting up against the member above them.
  const lead = index > 0 && lines[index - 1].trim() ? [''] : [];
  lines.splice(index, 0, ...lead, ...block, '');
  index += lead.length;
  fs.writeFileSync(outPath, lines.join('\n'));
  return { fallback, insertedAt: index + 1 };
}

function numberedLines(content) {
  return content.split('\n').map((line, i) => `${i + 1}: ${line}`);
}

function scanFillable(content) {
  const fillable = [];
  content.split('\n').forEach((line, i) => {
    if (line.includes('scaffold:inject')) {
      fillable.push({ line: i + 1, kind: 'marker' });
    } else if (/TODO|[Nn]ot [Ii]mplemented|NotImplementedException|NotImplementedError/.test(line)) {
      fillable.push({ line: i + 1, kind: 'todo' });
    }
  });
  return fillable;
}

function result(lang, template, outPath, marker) {
  const content = fs.readFileSync(outPath, 'utf8');
  return {
    path: path.resolve(outPath),
    language: lang,
    fileType: template,
    marker,
    content: numberedLines(content),
    fillable: scanFillable(content),
  };
}

function markerLineOf(outPath, marker) {
  const lines = fs.readFileSync(outPath, 'utf8').split('\n');
  const idx = lines.findIndex((l) => l.includes(marker));
  return idx === -1 ? null : idx + 1;
}

// Brownfield adoption: give an existing, never-scaffolded file its
// scaffold:inject marker so it becomes injectable from now on. Deliberately
// per-file and on-demand — the rest of the codebase stays untouched, and a
// legacy file is only adopted at the moment it is worked on.
function scaffoldAdopt({ lang, out, anchor }) {
  if (!fs.existsSync(out)) {
    throw new Error(`Cannot adopt, file does not exist: ${out}`);
  }
  const marker = meta.markerFor(lang);
  const original = fs.readFileSync(out, 'utf8');

  if (original.includes(marker)) {
    return {
      ...result(lang, null, out, marker),
      adopted: false,
      alreadyAdopted: true,
      markerLine: markerLineOf(out, marker),
    };
  }

  const { index, indent } = findAnchor(lang, original, anchor);
  const lines = original.split('\n');
  lines.splice(index, 0, `${indent}${marker}`);
  fs.writeFileSync(out, lines.join('\n'));

  return {
    ...result(lang, null, out, marker),
    adopted: true,
    alreadyAdopted: false,
    markerLine: index + 1,
  };
}

function scaffoldCreate({ lang, template, out, data = {}, force = false }) {
  validateData(lang, template, data);
  const rendered = render(lang, template, data);
  writeNewFile(out, rendered, force);
  return result(lang, template, out, meta.markerFor(lang));
}

// Inject a rendered template above the marker. If the file has never been
// scaffolded, it is adopted first (marker inserted at the anchor) and the
// injection proceeds — so working on a legacy file is one call, not a
// bootstrap step the caller has to remember. Adoption can be turned off for
// callers that want the old strict behavior.
function scaffoldInject({ lang, template, out, data = {}, marker, anchor, adopt = true }) {
  validateData(lang, template, data);
  const usedMarker = marker || meta.markerFor(lang);

  let adopted = false;
  let markerLine = null;
  if (fs.existsSync(out) && !fs.readFileSync(out, 'utf8').includes(usedMarker)) {
    if (!adopt) {
      throw new Error(
        `Marker "${usedMarker}" not found in: ${out}. Adopt the file first (scaffold_adopt) ` +
          `or pass an anchor, so later injections have a stable insertion point.`
      );
    }
    // Adoption uses the language's own marker; a caller-supplied override
    // would leave the file marked with something the next call won't find.
    if (marker && marker !== meta.markerFor(lang)) {
      throw new Error(
        `Cannot adopt ${out} with a custom marker "${marker}". Adopt it with the language default ` +
          `"${meta.markerFor(lang)}" first, or inject into a file that already carries your marker.`
      );
    }
    const adoption = scaffoldAdopt({ lang, out, anchor });
    adopted = adoption.adopted;
    markerLine = adoption.markerLine;
  }

  const rendered = render(lang, template, data);
  // The brace fallback only exists for files that were never adopted; with
  // adoption above, the marker is always present by this point.
  const { fallback, insertedAt } = injectIntoFile(out, rendered, usedMarker, {
    allowBraceFallback: false,
  });
  return {
    ...result(lang, template, out, usedMarker),
    insertedAt,
    fallback,
    adopted,
    markerLine: markerLine ?? markerLineOf(out, usedMarker),
  };
}

module.exports = {
  render,
  validateData,
  writeNewFile,
  injectIntoFile,
  numberedLines,
  scanFillable,
  scaffoldCreate,
  scaffoldInject,
  scaffoldAdopt,
};
