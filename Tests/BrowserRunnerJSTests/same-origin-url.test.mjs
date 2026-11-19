// Unit tests for ChickadeeUI.sameOriginURL, the check that the section-delete
// handlers (suite-table.js, assignments.js) run before a server-rendered
// `data-action` becomes a form target (CodeQL js/xss-through-dom).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ChickadeeUI = require('../../Public/chickadee-ui.js');

const origin = 'https://chickadee.example';

test('sameOriginURL resolves an in-app path to an absolute same-origin URL', () => {
  const { sameOriginURL } = ChickadeeUI;

  assert.equal(
    sameOriginURL('/instructor/abc123/sections/7/delete', origin),
    'https://chickadee.example/instructor/abc123/sections/7/delete',
  );
  assert.equal(sameOriginURL('sections/7/delete?x=1', origin), 'https://chickadee.example/sections/7/delete?x=1');
  assert.equal(sameOriginURL('https://chickadee.example/a', origin), 'https://chickadee.example/a');
});

test('sameOriginURL refuses a missing, foreign or script value', () => {
  const { sameOriginURL } = ChickadeeUI;

  assert.equal(sameOriginURL(null, origin), null);
  assert.equal(sameOriginURL(undefined, origin), null);
  assert.equal(sameOriginURL('', origin), null);
  assert.equal(sameOriginURL('https://evil.example/steal', origin), null);
  assert.equal(sameOriginURL('//evil.example/steal', origin), null);
  assert.equal(sameOriginURL('http://chickadee.example/a', origin), null);
  assert.equal(sameOriginURL('javascript:alert(1)', origin), null);
  assert.equal(sameOriginURL('data:text/html,<p>x</p>', origin), null);
});
