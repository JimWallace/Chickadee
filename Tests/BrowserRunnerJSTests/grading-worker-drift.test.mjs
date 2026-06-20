import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

// Guards against the shared Python snippets and exit-code logic in
// Public/grading-worker.js (Pyodide in a Web Worker) drifting from the canonical
// copies in Public/browser-runner.js (the main-thread fallback).  Both run the
// SAME per-script exec + env-config Python so the worker grader and the
// fallback grader produce byte-identical RAW output; if they drift, the same
// submission could grade differently depending on whether the browser had
// Worker support.  The Swift/native parity is pinned separately by
// Tests/Fixtures/output-contract.json.
//
// Each shared region is fenced with matching
//   CHICKADEE_DRIFT:<name>:BEGIN  …  CHICKADEE_DRIFT:<name>:END
// comment markers in both files.  Comparison normalizes whitespace (the worker
// uses 4-space JS indentation for var-style code while the fallback uses the
// runner's style), but the embedded Python template-literal bodies must match
// exactly.

const browserRunner = await fs.readFile(path.resolve('Public/browser-runner.js'), 'utf8');
const gradingWorker = await fs.readFile(path.resolve('Public/grading-worker.js'), 'utf8');

// The drift-fenced regions whose Python snippets must stay in sync.
const REGIONS = [
  'envConfigPython',
  'assignmentSeedPython',
  'STDOUT_REDIRECT_PY',
  'runScriptPython',
  'CAPTURE_OUTPUT_PY',
  'RESTORE_STREAMS_PY',
];

function extractRegion(source, name) {
  const begin = `CHICKADEE_DRIFT:${name}:BEGIN`;
  const end = `CHICKADEE_DRIFT:${name}:END`;
  const startIdx = source.indexOf(begin);
  const endIdx = source.indexOf(end);
  assert.notEqual(startIdx, -1, `missing ${begin} marker`);
  assert.notEqual(endIdx, -1, `missing ${end} marker`);
  assert.ok(endIdx > startIdx, `${end} appears before ${begin}`);
  // The body is between the end of the BEGIN marker line and the start of the
  // END marker line.
  const bodyStart = source.indexOf('\n', startIdx) + 1;
  const bodyEnd = source.lastIndexOf('\n', endIdx);
  return source.slice(bodyStart, bodyEnd);
}

// Normalize for comparison: drop full-line JS comments (the two files document
// the same snippet differently), collapse leading indentation, and trim
// trailing whitespace.  The Python *inside* the template literals is preserved
// verbatim (template-literal lines don't start with `//`), so any change to the
// executed Python is still caught.
function normalize(src) {
  return String(src)
    .split('\n')
    .map(line => line.replace(/[ \t]+$/, ''))
    .filter(line => !line.trim().startsWith('//'))
    .map(line => line.replace(/^[ \t]+/, ''))
    .join('\n')
    .trim();
}

for (const name of REGIONS) {
  test(`grading-worker.js shares the ${name} snippet with browser-runner.js`, () => {
    const fromRunner = normalize(extractRegion(browserRunner, name));
    const fromWorker = normalize(extractRegion(gradingWorker, name));
    assert.ok(fromRunner.length > 0, `${name} region in browser-runner.js is empty`);
    assert.equal(
      fromWorker,
      fromRunner,
      `Public/grading-worker.js ${name} drifted from Public/browser-runner.js — `
        + 'the worker grader and the main-thread fallback must run identical Python. '
        + 'Re-sync both copies.',
    );
  });
}
