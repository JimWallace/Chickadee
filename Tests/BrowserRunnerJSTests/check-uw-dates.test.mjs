// Unit tests for ChickadeeUI.checkUWDates — the UWaterloo important-date
// proximity warning, hoisted out of three inline template copies that had
// already drifted from each other in two ways: only one guarded `warningEl`
// against null, and the dashboard publish form used a shorter label.
//
// Both drift axes are pinned here, so a future re-inlining or a label change
// fails loudly.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ChickadeeUI = require('../../Public/chickadee-ui.js');

// The three surfaces that used to carry their own inline copy.  Each
// template's wiring now lives in a Public/*.js page file (the inline-script
// conversion), so the call site to verify is the wiring file; the template
// itself must stay free of any checkUWDates code.
const FORMERLY_INLINED = [
  { template: 'Resources/Views/assignment-new.leaf', wiring: 'Public/assignment-new-page.js' },
  { template: 'Resources/Views/_assignment-edit-body.leaf', wiring: 'Public/assignment-edit-page.js' },
  { template: 'Resources/Views/assignments.leaf', wiring: 'Public/assignments.js' },
];

function fakeEl() {
  return { style: { display: 'initial' }, textContent: '' };
}

/// Stubs global fetch with a single /api/v1/uw-dates payload for one call.
async function withDates(dates, fn) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = (url) => {
    calls.push(url);
    return Promise.resolve({ ok: true, json: () => Promise.resolve(dates) });
  };
  try {
    return await fn(calls);
  } finally {
    globalThis.fetch = original;
  }
}

const NEAR = [{ title: 'Reading Week', startDate: '2026-02-16T00:00:00Z', endDate: '2026-02-20T00:00:00Z' }];

test('a null warningEl is tolerated on every early-return path', async () => {
  // The pre-hoist create-page copy threw here; the edit-page copy did not.
  // Neither path should reach fetch, so no stub is needed.
  await assert.doesNotReject(() => ChickadeeUI.checkUWDates('', null));
  await assert.doesNotReject(() => ChickadeeUI.checkUWDates(null, null));
  await assert.doesNotReject(() => ChickadeeUI.checkUWDates('not-a-date', null));
});

test('a null warningEl is tolerated after the fetch resolves', async () => {
  await withDates(NEAR, async () => {
    await assert.doesNotReject(() => ChickadeeUI.checkUWDates('2026-02-18T09:00', null));
  });
});

test('an empty value hides the warning without fetching', async () => {
  const el = fakeEl();
  await withDates(NEAR, async (calls) => {
    await ChickadeeUI.checkUWDates('', el);
    assert.equal(el.style.display, 'none');
    assert.deepEqual(calls, [], 'no request should be made for an empty value');
  });
});

test('an unparseable value hides the warning without fetching', async () => {
  const el = fakeEl();
  await withDates(NEAR, async (calls) => {
    await ChickadeeUI.checkUWDates('not-a-date', el);
    assert.equal(el.style.display, 'none');
    assert.deepEqual(calls, []);
  });
});

test('a date inside the three-day window shows the default editor label', async () => {
  const el = fakeEl();
  await withDates(NEAR, async (calls) => {
    await ChickadeeUI.checkUWDates('2026-02-18T09:00', el);
    assert.deepEqual(calls, ['/api/v1/uw-dates']);
    assert.equal(el.style.display, '');
    assert.equal(el.textContent, '⚠ Due date is near: Reading Week');
  });
});

test('the dashboard publish form keeps its shorter label', async () => {
  const el = fakeEl();
  await withDates(NEAR, async () => {
    await ChickadeeUI.checkUWDates('2026-02-18T09:00', el, { label: 'Near:' });
    assert.equal(el.textContent, '⚠ Near: Reading Week');
  });
});

test('the three-day margin is applied on both sides, and a far date hides', async () => {
  const near = fakeEl();
  const far = fakeEl();
  await withDates(NEAR, async () => {
    // Two days before the start is still inside the margin.
    await ChickadeeUI.checkUWDates('2026-02-14T09:00', near);
    assert.equal(near.style.display, '');
    // Three weeks out is not.
    await ChickadeeUI.checkUWDates('2026-03-10T09:00', far);
    assert.equal(far.style.display, 'none');
    assert.equal(far.textContent, '');
  });
});

test('no template re-declares checkUWDates inline', async () => {
  for (const { template, wiring } of FORMERLY_INLINED) {
    const templateSrc = await fs.readFile(path.resolve(template), 'utf8');
    assert.ok(
      !templateSrc.includes('checkUWDates'),
      `${template} carries checkUWDates code; the page wiring lives in ${wiring}`,
    );
    const wiringSrc = await fs.readFile(path.resolve(wiring), 'utf8');
    assert.ok(
      !/function\s+checkUWDates\s*\(/.test(wiringSrc),
      `${wiring} declares checkUWDates locally; call ChickadeeUI.checkUWDates instead`,
    );
    assert.ok(
      wiringSrc.includes('ChickadeeUI.checkUWDates('),
      `${wiring} should reach the warning through ChickadeeUI.checkUWDates`,
    );
  }
});

test('a failed request leaves the element untouched rather than rejecting', async () => {
  const el = fakeEl();
  const original = globalThis.fetch;
  globalThis.fetch = () => Promise.reject(new Error('offline'));
  try {
    await assert.doesNotReject(() => ChickadeeUI.checkUWDates('2026-02-18T09:00', el));
    assert.equal(el.textContent, '');
  } finally {
    globalThis.fetch = original;
  }
});
