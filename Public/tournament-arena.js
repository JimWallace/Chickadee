// Public/tournament-arena.js
//
// The projector arena (docs/class-activities.md, "Projector arena"). A
// tournament on a browser-graded assignment puts no load on the runners: its
// matches wait for this page. "Play matches" on the present page plays them
// in the presenter's browser, one at a time, with the same grading stack a
// student's submit uses (`BrowserRunner.runScripts`). The home entrant's
// upload is the submission, the away entrant's is staged under `opponent/`,
// and the match seed is the one a runner would set. Each result goes back to
// the server, which decides the slot and opens the next round; the bracket
// below refreshes itself from the server.
//
// `playMatches` takes everything it touches as arguments, so the loop runs
// under node (tournament-arena.test.mjs). The wiring at the bottom binds it
// to the page.
(function () {
    'use strict';

    /// Plays every waiting match, in order, until none waits. Returns the
    /// number of matches whose result the server took. Throws on the first
    /// failure, so a broken match stops the arena and stays waiting.
    ///
    /// `deps`: { fetch, runScripts, csrfToken, report(text, kind) }.
    async function playMatches(setupID, deps) {
        var base = '/testsetups/' + encodeURIComponent(setupID) + '/arena';
        var played = 0;
        for (;;) {
            var next = await deps.fetch(base + '/next', { credentials: 'same-origin' });
            if (next.status === 204) {
                deps.report(played === 0 ? 'No match is waiting.' : matchCountText(played) + ' played. No match is waiting.', 'ok');
                return played;
            }
            if (!next.ok) throw new Error('Could not read the next match (' + next.status + ').');
            var match = await next.json();
            deps.report(matchText(match));

            var home = await fetchSubmission(deps, base, match.matchSubmissionID);
            var away = await fetchSubmission(deps, base, match.awaySubmissionID);
            var result = await deps.runScripts(home, setupID, {
                filename: match.homeFilename || 'submission.ipynb',
                opponentSubmission: {
                    bytes: away,
                    filename: match.awayFilename || 'submission.ipynb',
                    seed: match.matchSeed,
                },
            });

            var posted = await deps.fetch(
                base + '/matches/' + encodeURIComponent(match.matchSubmissionID) + '/result', {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'content-type': 'application/json', 'x-csrf-token': deps.csrfToken },
                    body: JSON.stringify({ collection: JSON.stringify(result.collection) }),
                });
            // 409: another presenter played this match first. Its result
            // stands, and the loop moves on to whatever waits next.
            if (posted.status === 409) continue;
            if (!posted.ok) throw new Error('The server did not take the result (' + posted.status + ').');
            played += 1;
        }
    }

    async function fetchSubmission(deps, base, submissionID) {
        var res = await deps.fetch(
            base + '/submissions/' + encodeURIComponent(submissionID), { credentials: 'same-origin' });
        if (!res.ok) throw new Error('Could not download an entrant (' + res.status + ').');
        return new Uint8Array(await res.arrayBuffer());
    }

    /// "Playing round 2, match 3". The bracket below lists each round's
    /// matches in this order, so the room finds the pairing there by its
    /// handles; the arena names no student.
    function matchText(match) {
        return 'Playing round ' + match.round + ', match ' + (match.position + 1);
    }

    function matchCountText(count) {
        return count === 1 ? '1 match' : count + ' matches';
    }

    var api = { playMatches: playMatches, matchText: matchText };

    if (typeof module === 'object' && module.exports) {
        module.exports = api;
        return;
    }

    // ── Page wiring ──
    var root = document.querySelector('[data-arena-setup-id]');
    if (!root) return;
    var button = root.querySelector('[data-arena-play]');
    var status = root.querySelector('[data-arena-status]');
    if (!button || !status) return;

    function report(text, kind) {
        ChickadeeUI.setStatus(status, text, kind);
    }

    button.addEventListener('click', async function () {
        if (!window.BrowserRunner) {
            report('The grading runtime did not load. Reload the page.', 'error');
            return;
        }
        button.disabled = true;
        try {
            await playMatches(root.dataset.arenaSetupId, {
                fetch: window.fetch.bind(window),
                runScripts: window.BrowserRunner.runScripts,
                csrfToken: ChickadeeUI.getCsrfToken(),
                report: report,
            });
        } catch (e) {
            report('The arena stopped: ' + (e && e.message ? e.message : String(e)), 'error');
        } finally {
            button.disabled = false;
        }
    });
}());
