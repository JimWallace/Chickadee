// The browser router's interpreter-to-substrate table (#2388). It is
// GENERATED into browser-runner.js by scripts/generate-js-constants.sh, which
// format-lint runs with --check. These tests pin what the router does with it.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const runnerSource = fs.readFileSync(path.resolve('Public/browser-runner.js'), 'utf8');
const executorsSource = fs.readFileSync(path.resolve('Public/grading-executors.js'), 'utf8');

/// The object literal of one generated `const NAME = { ... };` block.
function generatedTable(name) {
  const match = runnerSource.match(new RegExp(`const ${name} = (\\{[^}]*\\});`));
  assert.ok(match, `browser-runner.js has no generated ${name}`);
  return vm.runInNewContext(`(${match[1]})`);
}

function loadExecutors() {
  const context = { console, setTimeout, clearTimeout, TextDecoder };
  context.globalThis = context;
  vm.runInContext(executorsSource, vm.createContext(context), { filename: 'grading-executors.js' });
  return context.ChickadeeGradingExecutors;
}

test('every kernel language with a grading worker has an interpreter, and only those', () => {
  const kinds = generatedTable('INTERPRETER_KINDS');
  const workers = generatedTable('GRADING_WORKER_SCRIPTS');
  assert.deepEqual(Object.values(kinds).sort(), Object.keys(workers).sort());
});

test('interpreterToKind routes through the generated table', () => {
  const { interpreterToKind } = loadExecutors();
  const kinds = generatedTable('INTERPRETER_KINDS');
  for (const [interp, kind] of Object.entries(kinds)) {
    assert.equal(interpreterToKind(interp, kinds), kind);
  }
  assert.equal(interpreterToKind('rscript', kinds), 'r');
  assert.equal(interpreterToKind('bash', kinds), 'shell');
  assert.equal(interpreterToKind('ruby', kinds), 'unsupported');
  // A language the table names is routable without any edit to the router.
  assert.equal(interpreterToKind('newlang', { ...kinds, newlang: 'newlang' }), 'newlang');
  // Object prototype names are not interpreters.
  assert.equal(interpreterToKind('toString', kinds), 'unsupported');
});
