import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

// Pins Public/browser-runner.js's R_KERNEL_NAMES to the canonical Swift set,
// AssignmentLanguage.rKernelNames in Sources/Core/AssignmentLanguage.swift.
//
// The R-kernel alias list decides whether a notebook submission is extracted to
// .R or .py. It used to be hand-inlined in three places — two Swift call sites
// and this one in JS — so adding an alias meant finding all three, and missing
// the JS copy would silently grade browser submissions as Python. The Swift
// sites now all route through AssignmentLanguage.isRNotebookMetadata; the
// browser cannot import Swift, so this test is what keeps the last copy honest.

const SWIFT_SOURCE = 'Sources/Core/AssignmentLanguage.swift';
const JS_SOURCE = 'Public/browser-runner.js';

async function read(rel) {
  return fs.readFile(path.resolve(rel), 'utf8');
}

/** Parse `public static let rKernelNames: Set<String> = ["ir", "r", ...]`. */
function parseSwiftKernelNames(src) {
  const m = src.match(/rKernelNames\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]/);
  assert.ok(m, `could not find rKernelNames in ${SWIFT_SOURCE}`);
  return [...m[1].matchAll(/"([^"]+)"/g)].map(x => x[1]);
}

/** Parse `const R_KERNEL_NAMES = ['ir', 'r', ...];`. */
function parseJSKernelNames(src) {
  const m = src.match(/const\s+R_KERNEL_NAMES\s*=\s*\[([^\]]*)\]/);
  assert.ok(m, `could not find R_KERNEL_NAMES in ${JS_SOURCE}`);
  return [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1]);
}

test('browser-runner R_KERNEL_NAMES matches Swift AssignmentLanguage.rKernelNames', async () => {
  const swift = parseSwiftKernelNames(await read(SWIFT_SOURCE));
  const js = parseJSKernelNames(await read(JS_SOURCE));

  assert.ok(swift.length > 0, 'Swift kernel-name set parsed empty');
  assert.deepEqual(
    [...js].sort(),
    [...swift].sort(),
    'browser-runner.js R_KERNEL_NAMES has drifted from AssignmentLanguage.rKernelNames — ' +
      'update both, or the browser will disagree with the worker about what an R notebook is'
  );
});

test('R_KERNEL_NAMES entries are lowercase (the sniff lowercases before comparing)', async () => {
  const js = parseJSKernelNames(await read(JS_SOURCE));
  for (const name of js) {
    assert.equal(name, name.toLowerCase(), `${name} must be lowercase`);
  }
});
