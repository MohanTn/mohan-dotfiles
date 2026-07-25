'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const core = require('../lib/core');
const meta = require('../lib/template-meta');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'scaffold-core-test-'));
}

test('templateMeta computes required vs optional fields from the template body', () => {
  const m = meta.templateMeta('typescript', 'member');
  assert.ok(m.required.includes('Signature'));
  assert.ok(m.optional.includes('Body'));
  assert.ok(!m.required.includes('Body'));
  assert.match(m.dataComment, /^Data:/);
});

test('markerFor defaults to # for python/sh and // otherwise', () => {
  assert.equal(meta.markerFor('python'), '# scaffold:inject');
  assert.equal(meta.markerFor('sh'), '# scaffold:inject');
  assert.equal(meta.markerFor('typescript'), '// scaffold:inject');
});

test('listLanguages finds all six template folders', () => {
  const langs = meta.listLanguages();
  for (const lang of ['csharp', 'typescript', 'javascript', 'python', 'go', 'sh']) {
    assert.ok(langs.includes(lang), `missing ${lang}`);
  }
});

test('scaffoldCreate rejects missing required fields, naming them, and writes nothing', () => {
  const out = path.join(tmpDir(), 'orders-controller.ts');
  assert.throws(
    () => core.scaffoldCreate({ lang: 'typescript', template: 'controller', out, data: {} }),
    (err) => /EntityName/.test(err.message) && /ServiceType/.test(err.message) && /ServiceParam/.test(err.message)
  );
  assert.equal(fs.existsSync(out), false);
});

test('scaffoldCreate result matches the file on disk, with marker and fillable lines', () => {
  const out = path.join(tmpDir(), 'orders-controller.ts');
  const result = core.scaffoldCreate({
    lang: 'typescript',
    template: 'controller',
    out,
    data: { EntityName: 'Orders', RouteBase: '/orders', ServiceType: 'OrdersService', ServiceParam: 'ordersService' },
  });

  const disk = fs.readFileSync(out, 'utf8');
  assert.deepEqual(result.content, disk.split('\n').map((l, i) => `${i + 1}: ${l}`));
  assert.equal(result.fileType, 'controller');
  assert.equal(result.marker, '// scaffold:inject');

  const markerEntry = result.fillable.find((f) => f.kind === 'marker');
  assert.ok(markerEntry, 'fillable must contain the marker line');
  assert.equal(disk.split('\n')[markerEntry.line - 1].includes('scaffold:inject'), true);
});

test('scaffoldInject into python defaults to the # marker without a marker argument', () => {
  const out = path.join(tmpDir(), 'orders_controller.py');
  core.scaffoldCreate({ lang: 'python', template: 'controller', out, data: { EntityName: 'Orders', RouteBase: '/orders' } });

  const result = core.scaffoldInject({
    lang: 'python',
    template: 'member',
    out,
    data: { Signature: 'async def list_orders(db)' },
  });

  assert.equal(result.marker, '# scaffold:inject');
  assert.equal(result.fallback, false);
  assert.match(fs.readFileSync(out, 'utf8'), /async def list_orders\(db\)[\s\S]*# scaffold:inject/);
});

// Regression: the go controller marker used to sit inside RegisterRoutes, so
// an injected handler became a method declaration nested in a function body —
// invalid Go. A marker meant for `member` injection must be at declaration
// scope, not in a statement slot. Found by end-to-end test, not by unit tests.
test('go controller injects handler methods at file scope, not inside RegisterRoutes', () => {
  const out = path.join(tmpDir(), 'svc.go');
  core.scaffoldCreate({
    lang: 'go',
    template: 'controller',
    out,
    data: { Package: 'shop', EntityName: 'Orders', ServiceType: 'OrdersService', ServiceField: 'svc' },
  });

  core.scaffoldInject({
    lang: 'go',
    template: 'member',
    out,
    data: { Signature: 'func (c *OrdersController) list(w http.ResponseWriter, r *http.Request)' },
  });

  const lines = fs.readFileSync(out, 'utf8').split('\n');
  const registerStart = lines.findIndex((l) => l.includes('RegisterRoutes'));
  const registerEnd = registerStart + lines.slice(registerStart).findIndex((l) => l === '}');
  const methodLine = lines.findIndex((l) => l.startsWith('func (c *OrdersController) list('));

  assert.ok(methodLine > registerEnd, 'handler method must land after RegisterRoutes closes');
  assert.ok(lines.includes('// scaffold:inject'), 'marker stays at file scope for the next injection');
});

// --- brownfield: progressive adoption -------------------------------------
// A legacy file is adopted at the moment it is worked on, never in bulk, and
// injecting into one is a single call — there is no "unmarked file" path that
// falls back to hand-writing.

test('scaffoldInject adopts an unmarked legacy C# class and injects at member depth', () => {
  const out = path.join(tmpDir(), 'OrdersController.cs');
  fs.writeFileSync(
    out,
    'public class OrdersController : ControllerBase\n{\n    public IActionResult Get(int id)\n    {\n        return Ok(id);\n    }\n}\n'
  );

  const result = core.scaffoldInject({
    lang: 'csharp',
    template: 'member',
    out,
    data: { Signature: 'IActionResult List()' },
  });

  assert.equal(result.adopted, true);
  const lines = fs.readFileSync(out, 'utf8').split('\n');
  // marker inside the class, at member indentation, not at file scope
  const markerLine = lines.find((l) => l.includes('scaffold:inject'));
  assert.equal(markerLine, '    // scaffold:inject');
  // injected member is indented to the class body, and its own body one deeper
  assert.ok(lines.includes('    public IActionResult List()'));
  assert.ok(lines.includes('        throw new NotImplementedException(); // TODO: fill in'));
  // the original member survived untouched
  assert.ok(lines.includes('        return Ok(id);'));
});

test('scaffoldInject adopts an unmarked python class at body indentation', () => {
  const out = path.join(tmpDir(), 'store.py');
  fs.writeFileSync(out, 'class OrderRepository:\n    def get(self, id):\n        return None\n');

  const result = core.scaffoldInject({
    lang: 'python',
    template: 'member',
    out,
    data: { Signature: 'def list_all(self)' },
  });

  assert.equal(result.adopted, true);
  const lines = fs.readFileSync(out, 'utf8').split('\n');
  assert.ok(lines.includes('    # scaffold:inject'));
  assert.ok(lines.includes('    def list_all(self):'));
  assert.ok(lines.includes('        raise NotImplementedError  # TODO: fill in'));
});

test('scaffoldInject adopts a module-shaped python file at module scope', () => {
  const out = path.join(tmpDir(), 'legacy_api.py');
  fs.writeFileSync(
    out,
    'from fastapi import APIRouter\n\nrouter = APIRouter()\n\n\n@router.get("/")\ndef list_orders():\n    return []\n'
  );

  core.scaffoldInject({
    lang: 'python',
    template: 'member',
    out,
    data: { Signature: 'def get_order(id: int)' },
  });

  const lines = fs.readFileSync(out, 'utf8').split('\n');
  assert.ok(lines.includes('# scaffold:inject'), 'module-shaped file keeps the marker at column 0');
  assert.ok(lines.includes('def get_order(id: int):'));
});

test('adoption is idempotent: a second inject does not add a second marker', () => {
  const out = path.join(tmpDir(), 'Repo.cs');
  fs.writeFileSync(out, 'public class Repo\n{\n    public void A() { }\n}\n');

  const first = core.scaffoldInject({ lang: 'csharp', template: 'member', out, data: { Signature: 'void B()' } });
  const second = core.scaffoldInject({ lang: 'csharp', template: 'member', out, data: { Signature: 'void C()' } });

  assert.equal(first.adopted, true);
  assert.equal(second.adopted, false, 'already-adopted file is not adopted again');
  const content = fs.readFileSync(out, 'utf8');
  assert.equal(content.match(/scaffold:inject/g).length, 1);
  assert.ok(content.indexOf('void B()') < content.indexOf('void C()'), 'members accumulate in order');
});

test('scaffoldAdopt alone marks a file without rendering anything', () => {
  const out = path.join(tmpDir(), 'Legacy.cs');
  fs.writeFileSync(out, 'public class Legacy\n{\n    public void A() { }\n}\n');

  const result = core.scaffoldAdopt({ lang: 'csharp', out });

  assert.equal(result.adopted, true);
  assert.equal(result.markerLine, 4);
  assert.equal(result.fileType, null);
  assert.equal(fs.readFileSync(out, 'utf8').split('\n')[3], '    // scaffold:inject');

  const again = core.scaffoldAdopt({ lang: 'csharp', out });
  assert.equal(again.adopted, false);
  assert.equal(again.alreadyAdopted, true);
});

test('scaffoldAdopt honours an explicit anchor by line number and by snippet', () => {
  const dir = tmpDir();
  const byLine = path.join(dir, 'ByLine.cs');
  fs.writeFileSync(byLine, 'public class A\n{\n    public void One() { }\n\n    public void Two() { }\n}\n');
  assert.equal(core.scaffoldAdopt({ lang: 'csharp', out: byLine, anchor: 3 }).markerLine, 3);

  const bySnippet = path.join(dir, 'BySnippet.cs');
  fs.writeFileSync(bySnippet, 'public class A\n{\n    public void One() { }\n\n    public void Two() { }\n}\n');
  assert.equal(core.scaffoldAdopt({ lang: 'csharp', out: bySnippet, anchor: 'void Two' }).markerLine, 5);
});

test('scaffoldAdopt refuses to guess when no safe anchor exists', () => {
  const out = path.join(tmpDir(), 'minified.ts');
  fs.writeFileSync(out, 'export const x=1;const y=2;\n');
  assert.throws(
    () => core.scaffoldAdopt({ lang: 'typescript', out }),
    /No top-level closing brace found[\s\S]*explicit anchor/
  );
  assert.equal(fs.readFileSync(out, 'utf8'), 'export const x=1;const y=2;\n', 'file untouched');
});

test('scaffoldAdopt rejects an ambiguous anchor snippet', () => {
  const out = path.join(tmpDir(), 'Dup.cs');
  fs.writeFileSync(out, 'public class A\n{\n    public void Run() { }\n    public void Run(int i) { }\n}\n');
  assert.throws(() => core.scaffoldAdopt({ lang: 'csharp', out, anchor: 'void Run' }), /not unique \(2 matches\)/);
});

test('scaffoldInject with adopt:false keeps the old strict behavior', () => {
  const out = path.join(tmpDir(), 'strict.py');
  fs.writeFileSync(out, 'class A:\n    def b(self):\n        pass\n');
  assert.throws(
    () => core.scaffoldInject({ lang: 'python', template: 'member', out, data: { Signature: 'def c(self)' }, adopt: false }),
    /Adopt the file first/
  );
});

test('adoption never touches a file it was not asked about', () => {
  const dir = tmpDir();
  const target = path.join(dir, 'Target.cs');
  const bystander = path.join(dir, 'Bystander.cs');
  fs.writeFileSync(target, 'public class Target\n{\n}\n');
  fs.writeFileSync(bystander, 'public class Bystander\n{\n}\n');

  core.scaffoldAdopt({ lang: 'csharp', out: target });

  assert.equal(fs.readFileSync(bystander, 'utf8'), 'public class Bystander\n{\n}\n');
});

test('member template treats Body as optional', () => {
  const out = path.join(tmpDir(), 'Holder.cs');
  fs.writeFileSync(out, 'class Holder {\n  // scaffold:inject\n}\n');
  const result = core.scaffoldInject({
    lang: 'csharp',
    template: 'member',
    out,
    data: { Signature: 'void Bar()' },
  });
  assert.ok(result.fillable.some((f) => f.kind === 'todo'), 'default TODO body should be fillable');
});
