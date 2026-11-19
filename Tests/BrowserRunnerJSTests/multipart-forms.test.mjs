// Unit tests for Public/multipart-forms.js.
//
// The interceptor resends every multipart submit with fetch, so that the CSRF
// token can travel in a header. `new FormData(form)` leaves out the submit
// button, but a native submit sends its name and value. The create page's
// hidden draft-action buttons carry `draftAction` that way, so before the
// interceptor appended the submitter, "Create Blank", "Clear" and "Create
// from Assignment" reached the server as a plain save and did nothing.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const source = await fs.readFile(path.resolve('Public/multipart-forms.js'), 'utf8');

/// A FormData stand-in: built from the form's own fields, as the real one is,
/// and recording what is appended.
class FakeFormData {
  constructor(form) { this.entries = form ? form.fields.slice() : []; }
  append(name, value) { this.entries.push([name, value]); }
}

function load() {
  let submitHandler = null;
  const fetches = [];
  const sandbox = {
    FormData: FakeFormData,
    CustomEvent: class { constructor(type) { this.type = type; } },
    ChickadeeUI: { getCsrfToken: () => 'token' },
    document: {
      addEventListener(type, fn) { if (type === 'submit') submitHandler = fn; },
    },
    window: { location: {} },
    fetch: (url, opts) => {
      fetches.push({ url, opts });
      return new Promise(() => {});
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(source, sandbox);
  return { submit: (event) => submitHandler(event), fetches };
}

function makeForm(fields) {
  return {
    enctype: 'multipart/form-data',
    method: 'post',
    action: '/instructor/new/save',
    fields,
    dispatchEvent() {},
    querySelector: () => null,
  };
}

function makeEvent(form, submitter) {
  return { target: form, submitter, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
}

test('a named submitter is sent with its value, to its formaction', () => {
  const h = load();
  const form = makeForm([['_csrf', 'x'], ['assignmentName', 'Lab 1']]);
  const submitter = {
    name: 'draftAction', value: 'create-assignment-notebook', disabled: false,
    getAttribute: (name) => (name === 'formaction' ? '/instructor/new/draft' : null),
  };
  h.submit(makeEvent(form, submitter));

  assert.equal(h.fetches.length, 1);
  assert.equal(h.fetches[0].url, '/instructor/new/draft');
  assert.deepEqual(
    h.fetches[0].opts.body.entries,
    [['_csrf', 'x'], ['assignmentName', 'Lab 1'], ['draftAction', 'create-assignment-notebook']]);
  // The button is disabled after the body is built, so its value is not lost.
  assert.equal(submitter.disabled, true);
});

test('an unnamed submitter adds nothing', () => {
  const h = load();
  const form = makeForm([['_csrf', 'x']]);
  const submitter = { name: '', value: '', disabled: false, getAttribute: () => null };
  h.submit(makeEvent(form, submitter));

  assert.deepEqual(h.fetches[0].opts.body.entries, [['_csrf', 'x']]);
  assert.equal(h.fetches[0].url, '/instructor/new/save');
});

test('a submit with no submitter sends the form fields alone', () => {
  const h = load();
  const form = makeForm([['_csrf', 'x']]);
  h.submit(makeEvent(form, null));

  assert.deepEqual(h.fetches[0].opts.body.entries, [['_csrf', 'x']]);
});
