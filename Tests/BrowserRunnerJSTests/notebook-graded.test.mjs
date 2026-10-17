// Unit tests for Public/notebook-graded.js, the graded toast on the notebook
// page (notebook views NB5). The pure half builds the toast's text, the poll
// back-off and the submission id. The wiring half runs in a vm against a small
// fake page with a fake clock: a watched submission is polled until it is
// done, then the guide is fetched again and the toast says the grade.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const Graded = require('../../Public/notebook-graded.js');
const here = path.dirname(fileURLToPath(import.meta.url));
const source = fs.readFileSync(path.join(here, '../../Public/notebook-graded.js'), 'utf8');

const guide = (attempt, results) => ({
  attempt,
  tasks: [{ checks: results.map((result, i) => ({ name: `t${i}`, kind: 'script', result })) }],
});

test('the poll backs off by half again, up to 10s', () => {
  assert.equal(Graded.nextDelay(1000), 1500);
  assert.equal(Graded.nextDelay(8000), 10000);
  assert.equal(Graded.nextDelay(10000), 10000);
});

test('a submission is done once the runner has left it', () => {
  assert.equal(Graded.isDone('pending'), false);
  assert.equal(Graded.isDone('assigned'), false);
  assert.equal(Graded.isDone('complete'), true);
  assert.equal(Graded.isDone(undefined), false);
});

test('the submission id comes from the attempt URL', () => {
  assert.equal(Graded.submissionID('/submissions/sub_42'), 'sub_42');
  assert.equal(Graded.submissionID('/submissions/sub_42?x=1'), 'sub_42');
  assert.equal(Graded.submissionID('/elsewhere'), null);
});

test('the toast says the attempt, the grade and the public checks', () => {
  const all = Graded.toastText(guide({ number: 3, pending: false, percent: 100, url: '/submissions/s3' }, ['pass', 'pass']));
  assert.equal(all.caption, 'Attempt 3 graded');
  assert.equal(all.grade, '100%');
  assert.equal(all.summary, 'All 2 checks passed.');
  assert.equal(all.perfect, true);
  assert.equal(all.url, '/submissions/s3');

  const some = Graded.toastText(guide({ number: 2, pending: false, percent: 56, url: '/s' }, ['pass', 'fail', 'error', null]));
  assert.equal(some.summary, '1 of 3 checks passed.');
  assert.equal(some.perfect, false);

  const one = Graded.toastText(guide({ number: 1, pending: false, percent: 0, url: '/s' }, ['fail']));
  assert.equal(one.summary, '0 of 1 check passed.');
  const none = Graded.toastText(guide({ number: 1, pending: false, percent: null, url: '/s' }, []));
  assert.equal(none.summary, '');
  assert.equal(none.grade, '');
});

test('there is no toast while the attempt grades, or before one', () => {
  assert.equal(Graded.toastText(guide({ number: 1, pending: true, url: '/s' }, [])), null);
  assert.equal(Graded.toastText(guide(null, [])), null);
});

function element() {
  const classes = new Set();
  return {
    hidden: true, textContent: '', href: '', listeners: {}, focused: false,
    classList: {
      toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
    },
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    focus() { this.focused = true; },
  };
}

function loadPage({ statuses, guides, inEditor = true }) {
  const parts = { caption: element(), grade: element(), summary: element() };
  const toast = element();
  toast.querySelector = (selector) => parts[selector.replace('.js-nb-graded-', '')];
  const elements = { 'nb-graded': toast, 'nb-graded-results': element(), 'nb-graded-close': element(), 'nb-submit': element() };
  const timers = [];
  let clock = 0;
  const polled = [];
  const listeners = {};
  const window = { addEventListener: (type, fn) => (listeners[type] = fn) };
  const context = {
    window,
    document: { getElementById: (id) => elements[id] ?? null },
    Date: { now: () => clock },
    setTimeout: (fn, ms) => { timers.push({ fn, at: clock + ms }); return timers.length; },
    clearTimeout: () => {},
    fetch: async (url) => {
      polled.push(url);
      return { ok: true, json: async () => ({ status: statuses.shift() ?? 'pending' }) };
    },
    ChickadeeNotebookGuide: { refresh: async () => guides.shift() ?? null, inEditor: () => inEditor },
  };
  context.self = context;
  vm.runInNewContext(source, context);
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  // Runs the next timer, at its time, and lets its promises settle.
  const tick = async () => {
    const next = timers.shift();
    if (!next) return false;
    clock = next.at;
    next.fn();
    for (let i = 0; i < 5; i++) await settle();
    return true;
  };
  return { api: context.ChickadeeGraded, toast, parts, elements, polled, timers, tick, listeners, now: () => clock };
}

test('a watched submission is polled until done, then the toast shows', async () => {
  const page = loadPage({
    statuses: ['pending', 'assigned', 'complete'],
    guides: [guide({ number: 4, pending: false, percent: 100, url: '/submissions/sub_4' }, ['pass', 'pass'])],
  });
  assert.equal(page.api.active(), true);
  page.api.watch('sub_4');
  await page.tick();
  await page.tick();
  assert.equal(page.toast.hidden, true);
  await page.tick();
  assert.deepEqual(page.polled, ['/api/v1/submissions/sub_4', '/api/v1/submissions/sub_4', '/api/v1/submissions/sub_4']);
  assert.equal(page.toast.hidden, false);
  // The text arrives a frame after the toast shows, so it is announced.
  assert.equal(page.parts.caption.textContent, '');
  await page.tick();
  assert.equal(page.parts.caption.textContent, 'Attempt 4 graded');
  assert.equal(page.parts.grade.textContent, '100%');
  assert.equal(page.parts.summary.textContent, 'All 2 checks passed.');
  assert.equal(page.elements['nb-graded-results'].href, '/submissions/sub_4');
  assert.equal(page.toast.classList.contains('is-perfect'), true);
  assert.equal(page.timers.length, 0);
});

test('the poll waits 1s, then longer, and gives up after 5 minutes with a link', async () => {
  const page = loadPage({ statuses: [], guides: [] });
  page.api.watch('sub_slow');
  const delays = [];
  let last = 0;
  while (page.toast.hidden && (await page.tick())) {
    delays.push(page.now() - last);
    last = page.now();
  }
  await page.tick();
  assert.equal(page.parts.caption.textContent, 'Still grading');
  assert.equal(page.elements['nb-graded-results'].href, '/submissions/sub_slow');
  assert.equal(delays[0], 1000);
  assert.equal(delays[1], 1500);
  assert.equal(Math.max(...delays), 10000);
  assert.ok(page.now() >= 5 * 60 * 1000 - 10000 && page.now() <= 5 * 60 * 1000 + 10000, `stopped at ${page.now()}`);
});

test('below 100% there are no stars, and Keep editing closes the toast', async () => {
  const page = loadPage({ statuses: [], guides: [guide({ number: 2, pending: false, percent: 56, url: '/s' }, ['pass', 'fail'])] });
  await page.api.graded('sub_2');
  await page.tick();
  assert.equal(page.toast.hidden, false);
  assert.equal(page.toast.classList.contains('is-perfect'), false);
  assert.equal(page.parts.summary.textContent, '1 of 2 checks passed.');
  page.elements['nb-graded-close'].listeners.click.forEach((fn) => fn());
  assert.equal(page.toast.hidden, true);
  assert.equal(page.elements['nb-submit'].focused, true);
});

test('when the guide cannot say the grade, the toast still links to the results', async () => {
  const page = loadPage({ statuses: [], guides: [null] });
  await page.api.graded('sub_9');
  await page.tick();
  assert.equal(page.toast.hidden, false);
  assert.equal(page.parts.caption.textContent, 'Attempt graded');
  assert.equal(page.parts.summary.textContent, 'The results page shows the grade.');
  assert.equal(page.elements['nb-graded-results'].href, '/submissions/sub_9');
});

test('a page opened while its attempt grades watches it with no toast', async () => {
  const page = loadPage({
    statuses: ['complete'],
    guides: [guide({ number: 5, pending: false, percent: 80, url: '/submissions/sub_5' }, ['pass'])],
  });
  page.listeners['chickadee:guide']({ detail: guide({ number: 5, pending: true, url: '/submissions/sub_5' }, []) });
  await page.tick();
  assert.deepEqual(page.polled, ['/api/v1/submissions/sub_5']);
  assert.equal(page.toast.hidden, true);
  // Only the first guide of the page starts a watch.
  page.listeners['chickadee:guide']({ detail: guide({ number: 6, pending: true, url: '/submissions/sub_6' }, []) });
  assert.equal(page.timers.length, 0);
});

test('without the editor extension the toast is not active', () => {
  const page = loadPage({ statuses: [], guides: [], inEditor: false });
  assert.equal(page.api.active(), false);
});
