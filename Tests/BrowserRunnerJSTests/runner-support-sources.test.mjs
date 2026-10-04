import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

// Public/runner-support-sources.js holds the runtime helpers that the browser
// runner writes into every grading workspace. scripts/generate-js-constants.sh
// writes it, and CI runs that script with --check. So the file always equals
// what the generator writes.
//
// These tests check the other half: what the generator writes IS the canonical
// files. The check is exact, byte for byte. The retired runtime-drift.test.mjs
// compared hand-copied literals with the canonical files and ignored comments.
// There are no hand copies now, so nothing can drift. What can still go wrong
// is the encoding, or the set of files that the generator finds.

const SUPPORT_DIR = path.resolve('Tools/runner-support');

// The rule that Plugins/EmbedRunnerSupport uses to find the runtime helpers.
// The generator uses the same rule, so both runners get the same set.
function isRuntimeHelper(name) {
  return name.startsWith('test_runtime.') || name === 'sitecustomize.py';
}

async function loadGenerated() {
  const source = await fs.readFile(path.resolve('Public/runner-support-sources.js'), 'utf8');
  const context = {};
  context.globalThis = context;
  const vmContext = vm.createContext(context);
  vm.runInContext(source, vmContext, { filename: 'runner-support-sources.js' });
  return context;
}

test('the generated map holds every runtime helper and nothing else', async () => {
  const onDisk = (await fs.readdir(SUPPORT_DIR)).filter(isRuntimeHelper).sort();
  // An empty directory listing would make the comparison below pass with an
  // empty map.
  assert.ok(onDisk.length > 0, 'found no runtime helpers in Tools/runner-support');

  const { ChickadeeRunnerSupportSources: sources } = await loadGenerated();
  assert.deepEqual(
    Object.keys(sources).sort(),
    onDisk,
    'Public/runner-support-sources.js does not hold the runtime helpers in '
      + 'Tools/runner-support. Run scripts/generate-js-constants.sh.',
  );
});

test('each generated entry is its canonical file, byte for byte', async () => {
  const { ChickadeeRunnerSupportSources: sources } = await loadGenerated();
  const names = Object.keys(sources);
  assert.ok(names.length > 0, 'the generated map is empty');

  for (const name of names) {
    const canonical = await fs.readFile(path.join(SUPPORT_DIR, name));
    assert.equal(typeof sources[name], 'string', `${name} is not a string`);
    assert.ok(
      Buffer.from(sources[name], 'utf8').equals(canonical),
      `The generated ${name} is not Tools/runner-support/${name}. The file is `
        + 'machine-written, so the encoder in scripts/generate-js-constants.sh '
        + 'is wrong.',
    );
  }
});

test('the file defines exactly one global, and its map is frozen', async () => {
  const context = await loadGenerated();
  assert.deepEqual(
    Object.keys(context).filter((key) => key !== 'globalThis'),
    ['ChickadeeRunnerSupportSources'],
  );
  assert.ok(Object.isFrozen(context.ChickadeeRunnerSupportSources));
});
