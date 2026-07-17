#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const Handlebars = require('handlebars');
const pkg = require('./package.json');

const DEFAULT_MARKER = '// scaffold:inject';

function printHelp() {
  console.log(`scaffold - render a Handlebars boilerplate and write or inject it

Usage:
  node scaffold.js --lang <lang> --template <name> --out <path> [options]

Required:
  --lang <lang>        subfolder under boilerplats/, e.g. csharp
  --template <name>    template file (without .hbs), e.g. controller
  --out <path>         file to create or inject into

Options:
  --data '<json>'       inline JSON passed to the template (default: {})
  --data-file <path>    JSON file passed to the template
  --inject               insert into an existing file instead of creating one
  --marker '<string>'    injection anchor (default: "${DEFAULT_MARKER}")
  --force                overwrite --out if it already exists (create mode only)
  -v, --version
  -h, --help

Notes:
  - Templates are plain Handlebars files under boilerplats/<lang>/<template>.hbs.
  - In --inject mode, rendered content is inserted directly above the marker
    line, and the marker is left in place so the file can be injected again.
  - If the marker isn't found, content is inserted before the file's last
    "}" as a generic fallback for brace-delimited languages.
`);
}

function parseArgs(argv) {
  const args = { data: '{}' };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '-h':
      case '--help':
        args.help = true;
        break;
      case '-v':
      case '--version':
        args.version = true;
        break;
      case '--inject':
        args.inject = true;
        break;
      case '--force':
        args.force = true;
        break;
      case '--lang':
        args.lang = argv[++i];
        break;
      case '--template':
        args.template = argv[++i];
        break;
      case '--out':
        args.out = argv[++i];
        break;
      case '--data':
        args.data = argv[++i];
        break;
      case '--data-file':
        args.dataFile = argv[++i];
        break;
      case '--marker':
        args.marker = argv[++i];
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function loadData(args) {
  if (args.dataFile) {
    return JSON.parse(fs.readFileSync(args.dataFile, 'utf8'));
  }
  return JSON.parse(args.data);
}

function render(lang, template, data) {
  const templatePath = path.join(__dirname, lang, `${template}.hbs`);
  if (!fs.existsSync(templatePath)) {
    const langDir = path.join(__dirname, lang);
    const available = fs.existsSync(langDir)
      ? fs.readdirSync(langDir).filter((f) => f.endsWith('.hbs')).map((f) => f.replace(/\.hbs$/, ''))
      : [];
    throw new Error(
      `Template not found: ${templatePath}\nAvailable templates for "${lang}": ${available.join(', ') || '(none)'}`
    );
  }
  const source = fs.readFileSync(templatePath, 'utf8');
  return Handlebars.compile(source)(data);
}

function writeNewFile(outPath, content, force) {
  if (fs.existsSync(outPath) && !force) {
    throw new Error(`File already exists: ${outPath} (use --inject or --force)`);
  }
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, content);
}

function injectIntoFile(outPath, content, marker) {
  if (!fs.existsSync(outPath)) {
    throw new Error(`Cannot inject, file does not exist: ${outPath}`);
  }
  const original = fs.readFileSync(outPath, 'utf8');
  const trimmedContent = content.trim();

  const markerIndex = original.indexOf(marker);
  if (markerIndex !== -1) {
    const updated =
      original.slice(0, markerIndex) + trimmedContent + '\n\n' + original.slice(markerIndex);
    fs.writeFileSync(outPath, updated);
    return { fallback: false };
  }

  const lastBraceIndex = original.lastIndexOf('}');
  if (lastBraceIndex === -1) {
    throw new Error(
      `Marker "${marker}" not found and no "}" fallback point available in: ${outPath}`
    );
  }
  const updated =
    original.slice(0, lastBraceIndex) + trimmedContent + '\n\n' + original.slice(lastBraceIndex);
  fs.writeFileSync(outPath, updated);
  return { fallback: true };
}

function main(argv) {
  const args = parseArgs(argv);

  if (args.help) {
    printHelp();
    return;
  }
  if (args.version) {
    console.log(pkg.version);
    return;
  }

  if (!args.lang || !args.template || !args.out) {
    printHelp();
    throw new Error('Missing required arguments: --lang, --template, --out');
  }

  const data = loadData(args);
  const content = render(args.lang, args.template, data);

  if (args.inject) {
    const marker = args.marker || DEFAULT_MARKER;
    const result = injectIntoFile(args.out, content, marker);
    if (result.fallback) {
      console.warn(`Marker "${marker}" not found, inserted before final "}" in ${args.out}`);
    }
    console.log(`Injected into ${args.out}`);
  } else {
    writeNewFile(args.out, content, args.force);
    console.log(`Created ${args.out}`);
  }
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

module.exports = { parseArgs, loadData, render, writeNewFile, injectIntoFile };
