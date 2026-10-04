// The two helpers that Public/grading-shared.js holds for every grading
// wrapper (#1963): the per-run nonce, which was copied into each of the four
// language modules, and the status-line parser that Lua and Octave shared by
// copy. Each language module now delegates to these, so this is where they
// are pinned.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/grading-shared.js'), 'utf8');

function load(context = {}) {
  context.self = context;
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  vm.runInContext(source, vmContext, { filename: 'grading-shared.js' });
  return context.ChickadeeGradingShared;
}

const shared = load({ console });

test('makeNonce is unguessable and fresh per call', () => {
  const a = shared.makeNonce();
  const b = shared.makeNonce();
  assert.notEqual(a, b);
  assert.match(a, /^[0-9a-f]{32}$/);
});

test('makeNonce falls back to Math.random where crypto is absent', () => {
  // The fallback exists for a test harness, so it is tested as one: a context
  // whose crypto throws.
  const noCrypto = load({ console, crypto: { getRandomValues() { throw new Error('no crypto'); } } });
  const a = noCrypto.makeNonce();
  assert.match(a, /^[0-9a-f]{16,}$/);
  assert.notEqual(a, noCrypto.makeNonce());
});

test('parseStatusRunOutput recovers the exit code and the script stdout', () => {
  const nonce = 'abc123';
  const kernelStdout = `hello\nworld\n${nonce}:status:2\n`;
  // Spread, because an object from the vm context has a different prototype.
  assert.deepEqual({ ...shared.parseStatusRunOutput(kernelStdout, nonce) }, {
    exitCode: 2,
    stdout: 'hello\nworld',
  });
});

test('parseStatusRunOutput anchors on the LAST marker', () => {
  const nonce = 'abc123';
  const text = `\n${nonce}:status:1\nreal output\n${nonce}:status:0\n`;
  assert.equal(shared.parseStatusRunOutput(text, nonce).exitCode, 0);
});

test('parseStatusRunOutput keeps a last line that had no trailing newline', () => {
  const nonce = 'abc123';
  assert.equal(
    shared.parseStatusRunOutput(`no trailing newline\n${nonce}:status:0\n`, nonce).stdout,
    'no trailing newline');
});

test('parseStatusRunOutput returns null when the wrapper never reported', () => {
  assert.equal(shared.parseStatusRunOutput('some partial output', 'abc123'), null);
  assert.equal(shared.parseStatusRunOutput('\nabc123:status:', 'abc123'), null);
  assert.equal(shared.parseStatusRunOutput('\nabc123:status:notanumber\n', 'abc123'), null);
  assert.equal(shared.parseStatusRunOutput('', 'abc123'), null);
  assert.equal(shared.parseStatusRunOutput(null, 'abc123'), null);
});

test('every language module delegates its nonce to this copy', async () => {
  // A second copy is the defect #1963 names. The modules may keep a one-line
  // delegating function; they may not keep the implementation.
  for (const lang of ['python', 'r', 'lua', 'octave']) {
    const moduleSource = await fs.readFile(path.resolve(`Public/${lang}-grading-shared.js`), 'utf8');
    assert.ok(!moduleSource.includes('getRandomValues'),
      `${lang}-grading-shared.js must not carry its own nonce implementation`);
  }
  for (const lang of ['lua', 'octave']) {
    const moduleSource = await fs.readFile(path.resolve(`Public/${lang}-grading-shared.js`), 'utf8');
    assert.ok(!moduleSource.includes("':status:'"),
      `${lang}-grading-shared.js must not carry its own status-line parser`);
  }
});
