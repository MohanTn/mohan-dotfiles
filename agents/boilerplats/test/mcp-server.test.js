'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

// ROOT is captured when mcp-server.js is required, so pin it to the temp
// area first: the tests scaffold into throwaway directories under tmpdir.
const TEST_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'scaffold-mcp-test-'));
process.env.SCAFFOLD_MCP_ROOT = TEST_ROOT;

const { createServer } = require('../mcp-server');
const { Client } = require('@modelcontextprotocol/sdk/client/index.js');
const { InMemoryTransport } = require('@modelcontextprotocol/sdk/inMemory.js');

async function connectedClient() {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  const client = new Client({ name: 'test-client', version: '0.0.0' });
  await Promise.all([createServer().connect(serverTransport), client.connect(clientTransport)]);
  return client;
}

function parse(result) {
  return JSON.parse(result.content[0].text);
}

test('scaffold_list returns all six languages with their templates', async () => {
  const client = await connectedClient();
  const { languages } = parse(await client.callTool({ name: 'scaffold_list', arguments: {} }));

  assert.deepEqual(Object.keys(languages).sort(), ['csharp', 'go', 'javascript', 'python', 'sh', 'typescript']);
  assert.equal(languages.typescript.length, 14);
  assert.ok(languages.typescript.includes('controller'));
  assert.ok(languages.typescript.includes('test-module'));
  assert.ok(languages.sh.includes('script'));
  assert.ok(languages.sh.includes('hook'));
  assert.ok(languages.sh.includes('hook-test'));
});

test('scaffold_list also returns required/optional fields and marker per template, so scaffold_create needs no follow-up scaffold_describe call', async () => {
  const client = await connectedClient();
  const { templates } = parse(await client.callTool({ name: 'scaffold_list', arguments: {} }));

  assert.ok(templates.typescript.controller.required.includes('EntityName'));
  assert.equal(templates.typescript.controller.markerDefault, '// scaffold:inject');
  assert.ok(templates.python.member.optional.includes('Body'));
  assert.equal(templates.python.member.markerDefault, '# scaffold:inject');
});

test('scaffold_describe reports fields, required/optional split, and per-language marker', async () => {
  const client = await connectedClient();
  const described = parse(
    await client.callTool({ name: 'scaffold_describe', arguments: { lang: 'python', template: 'member' } })
  );
  assert.equal(described.markerDefault, '# scaffold:inject');
  assert.ok(described.required.includes('Signature'));
  assert.ok(described.optional.includes('Body'));
});

test('scaffold_create result carries the full numbered content identical to disk', async () => {
  const client = await connectedClient();
  const out = path.join(TEST_ROOT, 'src', 'orders-controller.ts');
  const result = await client.callTool({
    name: 'scaffold_create',
    arguments: {
      lang: 'typescript',
      template: 'controller',
      out,
      data: { EntityName: 'Orders', RouteBase: '/orders', ServiceType: 'OrdersService', ServiceParam: 'ordersService' },
    },
  });

  assert.notEqual(result.isError, true);
  const parsed = parse(result);
  const disk = fs.readFileSync(out, 'utf8');
  assert.equal(parsed.content.map((l) => l.replace(/^\d+: /, '')).join('\n'), disk);
  assert.equal(parsed.fileType, 'controller');
  assert.ok(parsed.fillable.some((f) => f.kind === 'marker'));
});

test('scaffold_create with missing fields is an error naming the fields', async () => {
  const client = await connectedClient();
  const result = await client.callTool({
    name: 'scaffold_create',
    arguments: { lang: 'typescript', template: 'controller', out: path.join(TEST_ROOT, 'x.ts'), data: {} },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /EntityName/);
  assert.match(result.content[0].text, /ServiceParam/);
});

test('scaffold_create refuses paths outside the server root', async () => {
  const client = await connectedClient();
  const result = await client.callTool({
    name: 'scaffold_create',
    arguments: {
      lang: 'typescript',
      template: 'query',
      out: path.join(os.tmpdir(), '..', 'escape-query.ts'),
      data: { QueryName: 'Escape' },
    },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /outside the server root/);
});

test('scaffold_adopt marks a legacy file and reports the marker line', async () => {
  const client = await connectedClient();
  const out = path.join(TEST_ROOT, 'legacy', 'OrdersController.cs');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, 'public class OrdersController\n{\n    public void Get() { }\n}\n');

  const parsed = parse(await client.callTool({ name: 'scaffold_adopt', arguments: { lang: 'csharp', out } }));

  assert.equal(parsed.adopted, true);
  assert.equal(parsed.markerLine, 4);
  assert.equal(parsed.content[3], '4:     // scaffold:inject');
});

test('scaffold_inject auto-adopts a legacy file in one call', async () => {
  const client = await connectedClient();
  const out = path.join(TEST_ROOT, 'legacy', 'store.py');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, 'class OrderRepository:\n    def get(self, id):\n        return None\n');

  const parsed = parse(
    await client.callTool({
      name: 'scaffold_inject',
      arguments: { lang: 'python', template: 'member', out, data: { Signature: 'def list_all(self)' } },
    })
  );

  assert.equal(parsed.adopted, true);
  assert.equal(parsed.content.map((l) => l.replace(/^\d+: /, '')).join('\n'), fs.readFileSync(out, 'utf8'));
  assert.ok(parsed.content.some((l) => l.endsWith('    # scaffold:inject')));
  assert.ok(parsed.fillable.some((f) => f.kind === 'todo'), 'the new member body is reported as fillable');
});

test('scaffold_adopt errors with guidance rather than guessing an anchor', async () => {
  const client = await connectedClient();
  const out = path.join(TEST_ROOT, 'legacy', 'minified.ts');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, 'export const x=1;\n');

  const result = await client.callTool({ name: 'scaffold_adopt', arguments: { lang: 'typescript', out } });

  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /explicit anchor/);
  assert.equal(fs.readFileSync(out, 'utf8'), 'export const x=1;\n');
});

test('scaffold_inject round-trip reports insertedAt and updated content', async () => {
  const client = await connectedClient();
  const out = path.join(TEST_ROOT, 'src', 'inject-controller.ts');
  await client.callTool({
    name: 'scaffold_create',
    arguments: {
      lang: 'typescript',
      template: 'controller',
      out,
      data: { EntityName: 'Inject', RouteBase: '/i', ServiceType: 'S', ServiceParam: 's' },
    },
  });
  const result = await client.callTool({
    name: 'scaffold_inject',
    arguments: {
      lang: 'typescript',
      template: 'member',
      out,
      data: { Signature: "router.get('/', handler); function handler()" },
    },
  });
  assert.notEqual(result.isError, true);
  const parsed = parse(result);
  assert.equal(parsed.fallback, false);
  assert.ok(parsed.insertedAt >= 1);
  assert.equal(parsed.content.map((l) => l.replace(/^\d+: /, '')).join('\n'), fs.readFileSync(out, 'utf8'));
});
