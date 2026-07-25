#!/usr/bin/env node
'use strict';

// Stdio MCP server over lib/core.js — the agent-facing front of the
// boilerplate generator. Every create/inject result carries the file type,
// the marker, the fillable line numbers, and the FULL numbered file content,
// so the agent never re-reads a file it just scaffolded.
//
// Writes are confined to the server root (cwd by default, override with
// SCAFFOLD_MCP_ROOT) so a tool call can never scaffold outside the project.

const path = require('path');
function requireDep(name) {
  try {
    return require(name);
  } catch {
    return require(path.join(process.env.HOME || '', '.cache', 'boilerplats', 'node_modules', name));
  }
}
const { McpServer } = requireDep('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = requireDep('@modelcontextprotocol/sdk/server/stdio.js');
const { z } = requireDep('zod');

const core = require('./lib/core');
const meta = require('./lib/template-meta');
const pkg = require('./package.json');

const ROOT = path.resolve(process.env.SCAFFOLD_MCP_ROOT || process.cwd());

function resolveInRoot(out) {
  const resolved = path.resolve(ROOT, out);
  if (resolved !== ROOT && !resolved.startsWith(ROOT + path.sep)) {
    throw new Error(`Refusing to write outside the server root ${ROOT}: ${resolved}`);
  }
  return resolved;
}

function ok(result) {
  return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
}

function fail(err) {
  return { isError: true, content: [{ type: 'text', text: err.message }] };
}

function createServer() {
  const server = new McpServer({ name: 'scaffold', version: pkg.version });

  server.tool(
    'scaffold_list',
    'List every scaffolding language and its templates. Boilerplate files (controller, repository, handler, validator, factory, mapper, query, commands, request, response, di-injection, helper, member) MUST be created through scaffold_create, never hand-written.',
    {},
    async () => {
      try {
        const languages = {};
        for (const lang of meta.listLanguages()) {
          languages[lang] = meta.listTemplates(lang);
        }
        return ok({ languages });
      } catch (err) {
        return fail(err);
      }
    }
  );

  server.tool(
    'scaffold_describe',
    'Describe one template: the data fields it needs (required vs optional), its default inject marker, and its documentation comment. Call this before scaffold_create when unsure which fields to pass.',
    { lang: z.string(), template: z.string() },
    async ({ lang, template }) => {
      try {
        return ok(meta.templateMeta(lang, template));
      } catch (err) {
        return fail(err);
      }
    }
  );

  server.tool(
    'scaffold_create',
    'Create a new boilerplate file from a template. The result contains the file type, the scaffold:inject marker, the fillable line numbers, and the FULL numbered file content — do NOT re-read the file afterwards; edit it directly using the returned lines.',
    {
      lang: z.string().describe('language folder, e.g. typescript'),
      template: z.string().describe('template name, e.g. controller'),
      out: z.string().describe('output file path (absolute, or relative to the project root)'),
      data: z.record(z.string()).default({}).describe('template data fields (see scaffold_describe)'),
      force: z.boolean().default(false).describe('overwrite an existing file'),
    },
    async ({ lang, template, out, data, force }) => {
      try {
        return ok(core.scaffoldCreate({ lang, template, out: resolveInRoot(out), data, force }));
      } catch (err) {
        return fail(err);
      }
    }
  );

  server.tool(
    'scaffold_adopt',
    'Give an existing legacy file its scaffold:inject marker so it becomes injectable. Brownfield adoption is per-file and on-demand — adopt only the file you are about to work on, never the whole codebase. The result reports markerLine and the FULL numbered content; verify the marker landed in the intended scope from that, do NOT re-read the file. If the heuristic cannot find a safe insertion point it errors with candidate lines instead of guessing — pass anchor (line number or unique snippet the marker should precede) to place it yourself.',
    {
      lang: z.string(),
      out: z.string().describe('existing file to adopt'),
      anchor: z
        .union([z.number(), z.string()])
        .optional()
        .describe('1-based line number, or a unique snippet the marker should be inserted above'),
    },
    async ({ lang, out, anchor }) => {
      try {
        return ok(core.scaffoldAdopt({ lang, out: resolveInRoot(out), anchor }));
      } catch (err) {
        return fail(err);
      }
    }
  );

  server.tool(
    'scaffold_inject',
    'Add a member to an existing file through the generator (template "member" for a plain method/function stub). Works on ANY existing file, greenfield or legacy: if the file has never been scaffolded it is adopted automatically (marker inserted at the anchor) and the member is injected above it — never hand-write a new method into a boilerplate file instead. The marker defaults per language. The result reports adopted/markerLine/insertedAt and the FULL updated numbered content — do NOT re-read the file afterwards.',
    {
      lang: z.string(),
      template: z.string(),
      out: z.string().describe('existing file to inject into (adopted first if unmarked)'),
      data: z.record(z.string()).default({}),
      marker: z.string().optional().describe('override the per-language default marker'),
      anchor: z
        .union([z.number(), z.string()])
        .optional()
        .describe('where to place the marker if this file still has to be adopted'),
      adopt: z
        .boolean()
        .default(true)
        .describe('set false to require an existing marker instead of adopting'),
    },
    async ({ lang, template, out, data, marker, anchor, adopt }) => {
      try {
        return ok(
          core.scaffoldInject({ lang, template, out: resolveInRoot(out), data, marker, anchor, adopt })
        );
      } catch (err) {
        return fail(err);
      }
    }
  );

  return server;
}

if (require.main === module) {
  createServer()
    .connect(new StdioServerTransport())
    .catch((err) => {
      console.error(err.message);
      process.exit(1);
    });
}

module.exports = { createServer, resolveInRoot, ROOT };
