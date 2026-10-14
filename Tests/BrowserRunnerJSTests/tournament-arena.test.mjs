// Unit tests for Public/tournament-arena.js, the projector arena's loop
// (docs/class-activities.md, "Projector arena"). A fake server hands out
// matches; these pin what the loop downloads, what it asks the grader to
// run, what it posts back, and when it stops.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Arena = require('../../Public/tournament-arena.js');

const MATCH = {
  matchSubmissionID: 'sub_m1', homeFilename: 'sub_h.ipynb',
  awaySubmissionID: 'sub_a', awayFilename: 'sub_a.ipynb',
  round: 1, position: 0, homeSeed: 1, awaySeed: 2, matchSeed: 'f'.repeat(64),
};

function response(status, body) {
  return {
    status,
    ok: status >= 200 && status < 300,
    json: async () => body,
    arrayBuffer: async () => new TextEncoder().encode(String(body)).buffer,
  };
}

/// A fake server: `queue` is the matches /next hands out, in order;
/// `resultStatus` is the status each result post answers with.
function fakeServer(queue, resultStatus = () => 204) {
  const calls = [];
  const fetch = async (url, init = {}) => {
    calls.push({ url, init });
    if (url.endsWith('/next')) {
      const next = queue.shift();
      return next ? response(200, next) : response(204);
    }
    if (url.includes('/submissions/')) return response(200, 'bytes of ' + url.split('/').pop());
    if (url.endsWith('/result')) return response(resultStatus(url));
    return response(404);
  };
  return { fetch, calls };
}

function deps(server, runs, reports) {
  return {
    fetch: server.fetch,
    csrfToken: 'tok',
    report: (text, kind) => reports.push({ text, kind }),
    runScripts: async (bytes, setupID, options) => {
      runs.push({ bytes: new TextDecoder().decode(bytes), setupID, options });
      return { collection: { submissionID: 'browser', testSetupID: setupID } };
    },
  };
}

test('plays the home upload against the away entrant and posts the result', async () => {
  const server = fakeServer([MATCH]);
  const runs = [];
  const reports = [];
  const played = await Arena.playMatches('setup_1', deps(server, runs, reports));

  assert.equal(played, 1);
  assert.equal(runs.length, 1);
  assert.equal(runs[0].bytes, 'bytes of sub_m1');
  assert.equal(runs[0].setupID, 'setup_1');
  assert.equal(runs[0].options.filename, 'sub_h.ipynb');
  const opponent = runs[0].options.opponentSubmission;
  assert.equal(new TextDecoder().decode(opponent.bytes), 'bytes of sub_a');
  assert.equal(opponent.filename, 'sub_a.ipynb');
  assert.equal(opponent.seed, MATCH.matchSeed);

  const post = server.calls.find((c) => c.url.endsWith('/result'));
  assert.equal(post.url, '/testsetups/setup_1/arena/matches/sub_m1/result');
  assert.equal(post.init.method, 'POST');
  assert.equal(post.init.headers['x-csrf-token'], 'tok');
  const body = JSON.parse(post.init.body);
  assert.equal(JSON.parse(body.collection).testSetupID, 'setup_1');

  assert.equal(reports[0].text, 'Playing round 1, match 1');
  assert.deepEqual(reports.at(-1), { text: '1 match played. No match is waiting.', kind: 'ok' });
});

test('keeps playing until no match waits, and says so when none did', async () => {
  const second = { ...MATCH, matchSubmissionID: 'sub_m2', round: 2, homeSeed: 1, awaySeed: 3 };
  const server = fakeServer([MATCH, second]);
  const runs = [];
  const reports = [];
  assert.equal(await Arena.playMatches('s', deps(server, runs, reports)), 2);
  assert.deepEqual(runs.map((r) => r.bytes), ['bytes of sub_m1', 'bytes of sub_m2']);
  assert.equal(reports.at(-1).text, '2 matches played. No match is waiting.');

  const idleReports = [];
  assert.equal(await Arena.playMatches('s', deps(fakeServer([]), [], idleReports)), 0);
  assert.deepEqual(idleReports, [{ text: 'No match is waiting.', kind: 'ok' }]);
});

test('a match another presenter played is skipped, not counted', async () => {
  const server = fakeServer([MATCH], () => 409);
  const played = await Arena.playMatches('s', deps(server, [], []));
  assert.equal(played, 0);
});

test('a refused result stops the arena', async () => {
  const server = fakeServer([MATCH, { ...MATCH, matchSubmissionID: 'sub_m2' }], () => 500);
  const runs = [];
  await assert.rejects(
    Arena.playMatches('s', deps(server, runs, [])),
    /did not take the result \(500\)/);
  assert.equal(runs.length, 1);
});

test('a grading failure stops the arena before anything is posted', async () => {
  const server = fakeServer([MATCH]);
  const failing = {
    ...deps(server, [], []),
    runScripts: async () => { throw new Error('kernel did not boot'); },
  };
  await assert.rejects(Arena.playMatches('s', failing), /kernel did not boot/);
  assert.equal(server.calls.some((c) => c.url.endsWith('/result')), false);
});

test('the setup ID is escaped into every URL', async () => {
  const server = fakeServer([]);
  await Arena.playMatches('a/b', deps(server, [], []));
  assert.equal(server.calls[0].url, '/testsetups/a%2Fb/arena/next');
});

// The arena loads the grading stack the notebook page loads. A grading script
// added to one list and not the other would boot a runner that cannot find
// its globals on one page only.
test('the arena loads the notebook page grading scripts, in the same order', async () => {
  const fs = await import('node:fs/promises');
  const path = await import('node:path');
  const read = (file) => fs.readFile(path.resolve(file), 'utf8');
  const paths = (text) => [...text.matchAll(/"(\/[^"]+\.js)"/g)].map((m) => m[1]);

  const notebook = /private static let scripts = \[([\s\S]*?)\]/.exec(
    await read('Sources/APIServer/Views/NotebookBody.swift'));
  const arena = /static let beforeRunner = \[([\s\S]*?)\]/.exec(
    await read('Sources/APIServer/Views/BrowserGradingScripts.swift'));
  assert.ok(notebook && arena, 'a script list is missing');

  const arenaScripts = paths(arena[1]);
  const grading = paths(notebook[1]).filter((p) => !/notebook/.test(p));
  assert.deepEqual(arenaScripts, grading);
});
