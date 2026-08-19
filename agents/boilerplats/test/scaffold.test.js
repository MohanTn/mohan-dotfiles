'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseArgs, main, render, writeNewFile, injectIntoFile } = require('../scaffold');

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'scaffold-test-'));
}

test('parseArgs reads flags into an object', () => {
  const args = parseArgs([
    '--lang', 'csharp',
    '--template', 'controller',
    '--out', 'File.cs',
    '--data', '{"a":1}',
    '--inject',
    '--marker', '// mark',
  ]);
  assert.equal(args.lang, 'csharp');
  assert.equal(args.template, 'controller');
  assert.equal(args.out, 'File.cs');
  assert.equal(args.data, '{"a":1}');
  assert.equal(args.inject, true);
  assert.equal(args.marker, '// mark');
});

test('parseArgs rejects unknown flags', () => {
  assert.throws(() => parseArgs(['--bogus']), /Unknown argument/);
});

function captureLog(fn) {
  const logs = [];
  const original = console.log;
  console.log = (...args) => logs.push(args.join(' '));
  try {
    fn();
  } finally {
    console.log = original;
  }
  return logs.join('\n');
}

test('--list --json reports languages and per-template required/optional fields with no other flags', () => {
  const out = captureLog(() => main(['--list', '--json']));
  const parsed = JSON.parse(out);
  assert.ok(parsed.languages.typescript.includes('controller'));
  assert.ok(parsed.templates.typescript.controller.required.includes('EntityName'));
  assert.equal(parsed.templates.python.member.markerDefault, '# scaffold:inject');
});

test('--list --lang scopes to one language', () => {
  const out = captureLog(() => main(['--list', '--lang', 'sh', '--json']));
  const parsed = JSON.parse(out);
  assert.equal(parsed.lang, 'sh');
  assert.ok(parsed.templates.script);
  assert.ok(!parsed.templates.controller);
});

test('--describe --json reports one template\'s fields, matching --list', () => {
  const out = captureLog(() => main(['--describe', '--lang', 'python', '--template', 'member', '--json']));
  const parsed = JSON.parse(out);
  assert.ok(parsed.required.includes('Signature'));
  assert.ok(parsed.optional.includes('Body'));
  assert.equal(parsed.markerDefault, '# scaffold:inject');
});

test('--describe without --template is a hard error naming what is missing', () => {
  assert.throws(() => main(['--describe', '--lang', 'python']), /Missing required arguments for --describe/);
});

test('render compiles a template file with the given data', () => {
  const dir = tmpDir();
  fs.mkdirSync(path.join(dir, 'lang'));
  fs.writeFileSync(path.join(dir, 'lang', 'thing.hbs'), 'hello {{name}}');

  const originalDirname = path.join(__dirname, '..');
  // render() resolves templates relative to scaffold.js's own directory,
  // so exercise it through a template placed under the real boilerplats dir.
  fs.mkdirSync(path.join(originalDirname, '__test_lang__'), { recursive: true });
  fs.writeFileSync(path.join(originalDirname, '__test_lang__', 'thing.hbs'), 'hello {{name}}');
  try {
    const out = render('__test_lang__', 'thing', { name: 'World' });
    assert.equal(out, 'hello World');
  } finally {
    fs.rmSync(path.join(originalDirname, '__test_lang__'), { recursive: true, force: true });
  }
});

test('render throws with available templates listed when template is missing', () => {
  assert.throws(() => render('csharp', '__nope__', {}), /Template not found/);
});

test('writeNewFile creates parent dirs and writes content', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'nested', 'File.cs');
  writeNewFile(outPath, 'public class Foo {}', false);
  assert.equal(fs.readFileSync(outPath, 'utf8'), 'public class Foo {}');
});

test('writeNewFile refuses to overwrite an existing file without --force', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'File.cs');
  fs.writeFileSync(outPath, 'original');
  assert.throws(() => writeNewFile(outPath, 'new', false), /already exists/);
  assert.equal(fs.readFileSync(outPath, 'utf8'), 'original');
});

test('writeNewFile overwrites when --force is set', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'File.cs');
  fs.writeFileSync(outPath, 'original');
  writeNewFile(outPath, 'new', true);
  assert.equal(fs.readFileSync(outPath, 'utf8'), 'new');
});

test('injectIntoFile inserts content above the marker and keeps the marker', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'File.cs');
  fs.writeFileSync(outPath, 'class Foo {\n  // scaffold:inject\n}\n');

  const result = injectIntoFile(outPath, 'void Bar() {}', '// scaffold:inject');
  const updated = fs.readFileSync(outPath, 'utf8');

  assert.equal(result.fallback, false);
  assert.match(updated, /void Bar\(\) \{\}\n\n\s*\/\/ scaffold:inject/);
  assert.match(updated, /\/\/ scaffold:inject/);
});

test('injectIntoFile supports repeated injection above the same marker', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'File.cs');
  fs.writeFileSync(outPath, 'class Foo {\n  // scaffold:inject\n}\n');

  injectIntoFile(outPath, 'void First() {}', '// scaffold:inject');
  injectIntoFile(outPath, 'void Second() {}', '// scaffold:inject');
  const updated = fs.readFileSync(outPath, 'utf8');

  assert.match(updated, /First[\s\S]*Second[\s\S]*scaffold:inject/);
});

test('injectIntoFile falls back to inserting before the last "}" when marker is absent', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'File.cs');
  fs.writeFileSync(outPath, 'class Foo {\n  void Existing() {}\n}\n');

  const result = injectIntoFile(outPath, 'void Bar() {}', '// not-present');
  const updated = fs.readFileSync(outPath, 'utf8');

  assert.equal(result.fallback, true);
  assert.match(updated, /void Bar\(\) \{\}\n\n\}/);
});

test('injectIntoFile throws when the target file does not exist', () => {
  const dir = tmpDir();
  const outPath = path.join(dir, 'missing.cs');
  assert.throws(() => injectIntoFile(outPath, 'x', '// m'), /does not exist/);
});
