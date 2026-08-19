#!/usr/bin/env node
'use strict';

// Thin CLI over lib/core.js — the MCP server (mcp-server.js) is the other
// front over the same core, so both behave identically. --json prints the
// structured result (full numbered content + fillable lines) so callers
// never need to re-read the file they just scaffolded.

const fs = require('fs');
const core = require('./lib/core');
const meta = require('./lib/template-meta');
const pkg = require('./package.json');

function printHelp() {
  console.log(`scaffold - render a Handlebars boilerplate and write or inject it

Usage:
  node scaffold.js --list [--lang <lang>] [--json]
  node scaffold.js --describe --lang <lang> --template <name> [--json]
  node scaffold.js --lang <lang> --template <name> --out <path> [options]

Discovery (run these first, before hand-writing anything):
  --list                 all languages and templates; with --lang, that
                         language's templates plus each one's required/
                         optional data fields, default marker, and doc comment
                         — usually all scaffold_create needs, no --describe
                         round trip required
  --describe             one template in isolation: same fields --list gives,
                         for a single --lang/--template pair (needs both)

Required (create/inject/adopt):
  --lang <lang>        subfolder under boilerplats/, e.g. csharp
  --template <name>    template file (without .hbs), e.g. controller
  --out <path>         file to create or inject into

Options:
  --data '<json>'       inline JSON passed to the template (default: {})
  --data-file <path>    JSON file passed to the template
  --inject               insert into an existing file instead of creating one
  --adopt                only add the scaffold:inject marker to an existing
                         file (brownfield adoption), no template rendered
  --anchor '<line|text>' where to put the marker when adopting: a 1-based line
                         number, or a unique snippet it should precede
  --no-adopt             with --inject, fail instead of adopting an unmarked file
  --marker '<string>'    injection anchor (default per language:
                         "# scaffold:inject" for python/sh, else "// scaffold:inject")
  --force                overwrite --out if it already exists (create mode only)
  --json                 print the structured result (path, fileType, marker,
                         numbered content, fillable lines) instead of a message
  -v, --version
  -h, --help

Notes:
  - Templates are plain Handlebars files under boilerplats/<lang>/<template>.hbs.
  - Missing required data fields are a hard error, nothing is written.
  - In --inject mode, rendered content is inserted directly above the marker
    line, and the marker is left in place so the file can be injected again.
  - An existing file with no marker is ADOPTED automatically on --inject: the
    marker is placed at the end of the enclosing top-level block, then the
    member is injected. Brownfield adoption is per-file and on-demand.
  - If no safe anchor can be found, nothing is written — pass --anchor.
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
      case '--list':
        args.list = true;
        break;
      case '--describe':
        args.describe = true;
        break;
      case '--inject':
        args.inject = true;
        break;
      case '--adopt':
        args.adopt = true;
        break;
      case '--no-adopt':
        args.noAdopt = true;
        break;
      case '--anchor':
        args.anchor = argv[++i];
        break;
      case '--force':
        args.force = true;
        break;
      case '--json':
        args.json = true;
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

  if (args.list) {
    if (args.lang) {
      const templates = meta.listTemplatesWithMeta(args.lang);
      if (args.json) {
        console.log(JSON.stringify({ lang: args.lang, templates }, null, 2));
      } else {
        for (const [name, info] of Object.entries(templates)) {
          console.log(`${args.lang}/${name}`);
          console.log(`  required: ${info.required.join(', ') || '(none)'}`);
          console.log(`  optional: ${info.optional.join(', ') || '(none)'}`);
          console.log(`  marker:   ${info.markerDefault}`);
        }
      }
    } else {
      const languages = {};
      const templates = {};
      for (const lang of meta.listLanguages()) {
        languages[lang] = meta.listTemplates(lang);
        templates[lang] = meta.listTemplatesWithMeta(lang);
      }
      if (args.json) {
        console.log(JSON.stringify({ languages, templates }, null, 2));
      } else {
        for (const [lang, names] of Object.entries(languages)) {
          console.log(`${lang}: ${names.join(', ')}`);
        }
        console.log('\nRun --list --lang <lang> for required/optional fields per template.');
      }
    }
    return;
  }

  if (args.describe) {
    if (!args.lang || !args.template) {
      printHelp();
      throw new Error('Missing required arguments for --describe: --lang, --template');
    }
    const info = meta.templateMeta(args.lang, args.template);
    if (args.json) {
      console.log(JSON.stringify(info, null, 2));
    } else {
      console.log(`${args.lang}/${args.template}`);
      console.log(`  required: ${info.required.join(', ') || '(none)'}`);
      console.log(`  optional: ${info.optional.join(', ') || '(none)'}`);
      console.log(`  marker:   ${info.markerDefault}`);
      if (info.dataComment) console.log(`  doc:      ${info.dataComment}`);
    }
    return;
  }

  if (args.adopt) {
    if (!args.lang || !args.out) {
      printHelp();
      throw new Error('Missing required arguments for --adopt: --lang, --out');
    }
    const result = core.scaffoldAdopt({ lang: args.lang, out: args.out, anchor: args.anchor });
    if (args.json) {
      console.log(JSON.stringify(result, null, 2));
    } else if (result.alreadyAdopted) {
      console.log(`Already adopted: ${args.out} (marker on line ${result.markerLine})`);
    } else {
      console.log(`Adopted ${args.out} (marker on line ${result.markerLine})`);
    }
    return;
  }

  if (!args.lang || !args.template || !args.out) {
    printHelp();
    throw new Error('Missing required arguments: --lang, --template, --out');
  }

  const data = loadData(args);

  if (args.inject) {
    const result = core.scaffoldInject({
      lang: args.lang,
      template: args.template,
      out: args.out,
      data,
      marker: args.marker,
      anchor: args.anchor,
      adopt: !args.noAdopt,
    });
    if (args.json) {
      console.log(JSON.stringify(result, null, 2));
    } else {
      if (result.adopted) {
        console.log(`Adopted ${args.out} (marker on line ${result.markerLine})`);
      }
      console.log(`Injected into ${args.out}`);
    }
  } else {
    const result = core.scaffoldCreate({
      lang: args.lang,
      template: args.template,
      out: args.out,
      data,
      force: args.force,
    });
    if (args.json) {
      console.log(JSON.stringify(result, null, 2));
    } else {
      console.log(`Created ${args.out}`);
    }
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

module.exports = {
  parseArgs,
  loadData,
  main,
  // re-exported from lib/core for backward compatibility (tests, direct requires)
  render: core.render,
  writeNewFile: core.writeNewFile,
  injectIntoFile: core.injectIntoFile,
  meta,
};
