// Unit tests for Public/notebook-preflight-core.js, the DOM-free half of the
// student submit page's capability preflight. The wiring probes the browser;
// these pin what it does with the answers: which capability names a
// diagnostic reports, what counts as a low-memory device, what a diagnostic
// body carries (and caps), and the per-page budget on error reports, which is
// what stops a tight error loop from flooding the endpoint.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/notebook-preflight-core.js');

const ALL = { webAssembly: true, worker: true, serviceWorker: true, indexedDB: true };

test('missing capabilities are named in report order', () => {
  assert.deepEqual(Core.missingCapabilities(ALL), []);
  assert.deepEqual(Core.missingCapabilities({ ...ALL, indexedDB: false, webAssembly: false }), ['WebAssembly', 'indexedDB']);
  assert.deepEqual(Core.missingCapabilities({}), ['WebAssembly', 'Worker', 'serviceWorker', 'indexedDB']);
});

test('low memory is at most 2 GB of deviceMemory, and unknown is not low', () => {
  assert.equal(Core.isLowMemory(2), true);
  assert.equal(Core.isLowMemory(0.5), true);
  assert.equal(Core.isLowMemory(4), false);
  assert.equal(Core.isLowMemory(0), false);
  assert.equal(Core.isLowMemory(null), false);
});

test('the preflight result is ok only with nothing failed; low memory is a hint, not a failure', () => {
  assert.deepEqual(Core.preflightResult([], 8), { ok: true, failed: [], lowMemory: false, deviceMemory: 8 });
  assert.deepEqual(Core.preflightResult([], 1), { ok: true, failed: [], lowMemory: true, deviceMemory: 1 });
  assert.deepEqual(Core.preflightResult(['Worker'], undefined), { ok: false, failed: ['Worker'], lowMemory: false, deviceMemory: null });
});

test('the failure details block names the kind, the user agent and the failed checks', () => {
  assert.equal(Core.failureDetailsText({ kind: 'preflight_fail', failedChecks: ['indexedDB:open'] }, 'UA/1'),
    'Failure: preflight_fail\nUser-Agent: UA/1\nFailed checks: indexedDB:open');
  assert.equal(Core.failureDetailsText({ kind: 'watchdog_timeout' }, ''),
    'Failure: watchdog_timeout\nUser-Agent: (unknown)');
});

test('the reset link returns the student to this assignment, query included', () => {
  assert.equal(Core.resetEditorHref('/CS136/lab1', '?submissionID=s1'), '/reset-editor?next=%2FCS136%2Flab1%3FsubmissionID%3Ds1');
});

test('the app version is capped at 32 characters and absent when missing', () => {
  assert.equal(Core.appVersionFrom('0.5.220'), '0.5.220');
  assert.equal(Core.appVersionFrom('v'.repeat(40)).length, 32);
  assert.equal(Core.appVersionFrom(null), '');
  assert.equal(Core.appVersionFrom(''), '');
});

test('a diagnostic body carries only what is set, with client-side caps', () => {
  assert.deepEqual(Core.diagnosticBody({ kind: 'editor_ready' }, {}), { kind: 'editor_ready' });
  const body = Core.diagnosticBody(
    { kind: 'editor_error', failedChecks: [], message: 'm'.repeat(2500), stack: 's'.repeat(9000), source: 'x'.repeat(70) },
    { setupID: 'setup_1', appVersion: '0.5.220' });
  assert.equal(body.failedChecks, undefined);
  assert.equal(body.testSetupID, 'setup_1');
  assert.equal(body.appVersion, '0.5.220');
  assert.equal(body.message.length, 2000);
  assert.equal(body.stack.length, 8000);
  assert.equal(body.source.length, 64);
});

test('the error-report gate de-duplicates by source and message and stops at the cap', () => {
  const gate = Core.createErrorReportGate(2);
  assert.equal(gate.admit({ source: 'a', message: 'boom' }), true);
  assert.equal(gate.admit({ source: 'a', message: 'boom' }), false);
  assert.equal(gate.admit({ source: 'b', message: 'boom' }), true);
  assert.equal(gate.admit({ source: 'c', message: 'new' }), false, 'cap reached');
  assert.equal(gate.admit(null), false);
  assert.equal(Core.MAX_ERROR_REPORTS, 8);
});

test('telemetry events carry a bounded user agent and the device memory', () => {
  assert.deepEqual(Core.deviceWarningEvent(2), { kind: 'device_warning', source: 'low_memory', message: 'deviceMemory=2' });
  assert.deepEqual(Core.deviceWarningEvent(null), { kind: 'device_warning', source: 'low_memory', message: 'deviceMemory=unknown' });
  assert.equal(Core.slowBootEvent('u'.repeat(300)).message.length, 'ua='.length + 200);
  assert.deepEqual(Core.browserSupportEvent(''), { kind: 'browser_support', source: 'below_matrix', message: 'ua=' });
});

test('the fallback copy exists for the two non-generic variants and speaks to the student', () => {
  for (const variant of ['memory', 'slow']) {
    const copy = Core.FALLBACK_COPY[variant];
    assert.ok(copy.title.length > 0 && copy.text.includes('.ipynb'), variant + ' copy must offer the upload path');
  }
});

test('the notebook page loads the core before the preflight', async () => {
  const src = await fs.readFile(path.resolve('Resources/Views/_notebook-body.leaf'), 'utf8');
  const core = src.indexOf('/notebook-preflight-core.js');
  const wiring = src.indexOf('/notebook-preflight.js');
  assert.ok(core >= 0 && wiring >= 0 && core < wiring, 'core must be loaded before notebook-preflight.js');
});
