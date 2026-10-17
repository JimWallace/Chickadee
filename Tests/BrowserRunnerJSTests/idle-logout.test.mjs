// Public/idle-logout.js: the client half of the institutional idle-timeout
// policy. The server signs an idle session out on its next request; this
// script signs out a user who makes no request at all.
//
// The rules pinned here are the ones the script's header states: an absolute
// deadline, a warning that only an explicit choice dismisses, a tab that comes
// back from the background past the deadline signs out at once, and tabs share
// activity and sign-out through a BroadcastChannel.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

import { FakeClock, StubDocument, flushMicrotasks } from './support/dom-stub.mjs';

const source = fs.readFileSync(path.resolve('Public/idle-logout.js'), 'utf8');

function keyEvent(type, key) {
  const event = new Event(type, { cancelable: true });
  Object.defineProperty(event, 'key', { value: key });
  return event;
}

/// Runs the script on a page with the given meta values. Returns handles on
/// everything the script touches.
function boot({
  timeout = 60, warning = 20, withForm = true, broadcast = true,
  keepalive = () => Promise.resolve({ ok: true, json: async () => ({ secondsRemaining: timeout }) }),
  saveNotebook,
} = {}) {
  const clock = new FakeClock();
  const document = new StubDocument();
  if (timeout !== null) document.addMeta('session-idle-timeout-seconds', timeout);
  if (warning !== null) document.addMeta('session-idle-warning-seconds', warning);

  let form = null;
  if (withForm) {
    form = document.createElement('form');
    form.setAttribute('action', '/logout');
    form.submissions = [];
    form.requestSubmit = () => form.submissions.push(form.getAttribute('action'));
    document.body.appendChild(form);
  }

  const channels = [];
  class FakeBroadcastChannel {
    constructor(name) { this.name = name; this.posted = []; this.onmessage = null; channels.push(this); }
    postMessage(message) { this.posted.push(message); }
  }

  const window = new EventTarget();
  window.location = { href: '/dashboard' };
  if (broadcast) window.BroadcastChannel = FakeBroadcastChannel;
  if (saveNotebook) window.chickadeeSaveNotebook = saveNotebook;

  const fetches = [];
  const context = {
    window, document, console,
    ChickadeeUI: { getCsrfToken: () => 'csrf-token' },
    fetch: (url, init) => { fetches.push({ url, init }); return keepalive(url, init); },
  };
  if (broadcast) context.BroadcastChannel = FakeBroadcastChannel;
  clock.install(context);
  vm.runInContext(source, vm.createContext(context), { filename: 'idle-logout.js' });

  const overlay = () => document.querySelector('.cd-idle-overlay');
  return {
    clock, document, window, form, fetches,
    channel: channels[0],
    overlay,
    warningVisible: () => Boolean(overlay()) && !overlay().hasAttribute('hidden'),
    countdown: () => document.querySelector('.cd-idle-count')?.textContent,
  };
}

// MARK: - Dormant pages

test('a page with no idle timeout runs no watchdog', () => {
  for (const timeout of [null, 0]) {
    const page = boot({ timeout });
    assert.equal(page.clock.intervalCount, 0, `timeout ${timeout}`);
  }
});

test('a page with no logout form runs no watchdog', () => {
  const page = boot({ withForm: false });
  assert.equal(page.clock.intervalCount, 0);
});

// MARK: - The warning

test('the warning appears at the warning point and not before', () => {
  const page = boot({ timeout: 60, warning: 20 });

  page.clock.advance(39_000);
  assert.equal(page.warningVisible(), false);

  page.clock.advance(1_000);
  assert.equal(page.warningVisible(), true);
  assert.equal(page.document.activeElement.textContent, 'Stay signed in', 'focus moves to the safe choice');
  assert.equal(page.countdown(), '20 seconds');
});

test('the countdown reads in minutes above a minute and in seconds below', () => {
  const page = boot({ timeout: 600, warning: 125 });
  page.clock.advance(475_000);
  assert.equal(page.countdown(), '2:05');
  page.clock.advance(124_000);
  assert.equal(page.countdown(), '1 second');
});

test('a warning as long as the timeout is shortened to five seconds less', () => {
  const page = boot({ timeout: 10, warning: 30 });
  page.clock.advance(4_000);
  assert.equal(page.warningVisible(), false);
  page.clock.advance(1_000);
  assert.equal(page.warningVisible(), true);
});

// MARK: - Activity

test('activity before the warning moves the deadline', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(30_000);
  page.window.dispatchEvent(new Event('keydown'));

  page.clock.advance(39_000);
  await flushMicrotasks();
  assert.equal(page.warningVisible(), false);
  assert.deepEqual(page.form.submissions, []);
});

test('activity bridged from the notebook editor counts as activity', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(30_000);
  page.window.dispatchEvent(new Event('chickadee:activity'));

  page.clock.advance(35_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, []);
});

test('passive activity after the warning does not keep the session', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(40_000);
  page.window.dispatchEvent(new Event('mousedown'));

  page.clock.advance(20_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, ['/logout?reason=timeout']);
});

// MARK: - Signing out

test('at the deadline the real logout form is submitted and other tabs are told', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(60_000);
  await flushMicrotasks();

  assert.deepEqual(page.form.submissions, ['/logout?reason=timeout']);
  assert.ok(page.channel.posted.some(m => m.type === 'logout'));
});

test('a tab shown again after the deadline signs out with no timer firing', async () => {
  for (const wake of ['visibilitychange', 'focus', 'pageshow']) {
    const page = boot({ timeout: 60, warning: 20 });
    page.clock.jump(61_000);
    await flushMicrotasks();
    assert.deepEqual(page.form.submissions, [], `${wake}: nothing ran while hidden`);

    const target = wake === 'visibilitychange' ? page.document : page.window;
    target.dispatchEvent(new Event(wake));
    await flushMicrotasks();
    assert.deepEqual(page.form.submissions, ['/logout?reason=timeout'], wake);
  }
});

test('an open notebook is saved before the sign-out', async () => {
  const order = [];
  const page = boot({ saveNotebook: async () => { order.push('saved'); } });
  page.clock.advance(60_000);
  await flushMicrotasks();
  order.push(...page.form.submissions);
  assert.deepEqual(order, ['saved', '/logout?reason=timeout']);
});

test('a notebook save that never finishes delays the sign-out by three seconds only', async () => {
  const page = boot({ saveNotebook: () => new Promise(() => {}) });
  page.clock.advance(60_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, []);

  page.clock.advance(3_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, ['/logout?reason=timeout']);
});

test('without BroadcastChannel the watchdog still signs out', async () => {
  const page = boot({ broadcast: false });
  page.clock.advance(60_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, ['/logout?reason=timeout']);
});

// MARK: - Staying signed in

test('"Stay signed in" asks the server, then hides the warning and resets the clock', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(40_000);
  page.document.activeElement.dispatchEvent(new Event('click'));
  await flushMicrotasks();

  assert.equal(page.fetches.length, 1);
  assert.equal(page.fetches[0].url, '/session/keepalive');
  assert.equal(page.fetches[0].init.method, 'POST');
  assert.equal(page.fetches[0].init.headers['x-csrf-token'], 'csrf-token');
  assert.equal(page.warningVisible(), false);

  page.clock.advance(39_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, []);
});

test('Escape in the warning means "Stay signed in"', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(40_000);
  const escape = keyEvent('keydown', 'Escape');
  page.overlay().dispatchEvent(escape);
  await flushMicrotasks();

  assert.equal(escape.defaultPrevented, true);
  assert.equal(page.fetches.length, 1);
  assert.equal(page.warningVisible(), false);
});

test('a keepalive the server refuses, or that cannot reach it, signs out', async () => {
  const refusals = [
    () => Promise.resolve({ ok: false }),
    () => Promise.reject(new Error('offline')),
  ];
  for (const keepalive of refusals) {
    const page = boot({ keepalive });
    page.clock.advance(40_000);
    page.document.activeElement.dispatchEvent(new Event('click'));
    await flushMicrotasks();
    await flushMicrotasks();
    assert.deepEqual(page.form.submissions, ['/logout?reason=timeout']);
  }
});

// MARK: - Other tabs

test('a sign-out in another tab sends this tab to the login page', () => {
  const page = boot();
  page.channel.onmessage({ data: { type: 'logout' } });
  assert.equal(page.window.location.href, '/login?error=timeout');
});

test('activity in another tab dismisses this tab\'s warning and moves its deadline', async () => {
  const page = boot({ timeout: 60, warning: 20 });
  page.clock.advance(40_000);
  assert.equal(page.warningVisible(), true);

  page.channel.onmessage({ data: { type: 'extend', deadline: page.clock.now + 60_000 } });
  assert.equal(page.warningVisible(), false);

  page.clock.advance(39_000);
  await flushMicrotasks();
  assert.deepEqual(page.form.submissions, []);
});
