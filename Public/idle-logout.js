// Public/idle-logout.js
//
// Client-side inactivity watchdog. Required by the institutional security
// policy: an authenticated user who stops interacting must be signed out and
// returned to the login page after a fixed idle period (default 30 minutes).
//
// The server enforces this on the *next* request via
// SessionIdleTimeoutMiddleware, but a user who simply sits on a page (or whose
// tab is backgrounded) makes no requests, so the server never gets a chance to
// redirect them. This script closes that gap.
//
// Design notes:
//
//   * Absolute deadline, not a poll-vs-stamp comparison. We track
//     `deadline = lastActivity + timeout`. A coarse 1 s interval drives the
//     foreground countdown, but the load-bearing trigger is the
//     `visibilitychange`/`focus` listener: browsers freeze timers in a
//     backgrounded tab, so a tab hidden past the ceiling would never fire on
//     the interval alone. Re-evaluating the instant the tab is shown again
//     means a user returning to a long-idle tab is logged out immediately,
//     with no click required.
//
//   * Warning modal. `warningSeconds` before the ceiling we raise a modal with
//     a live countdown and a "Stay signed in" button. Only an explicit click
//     (or genuine activity in another tab) extends the session — once the modal
//     is up, passive mouse drift in this tab is ignored, since the whole point
//     is to confirm a human is present.
//
//   * Cross-tab sync via BroadcastChannel. Activity / extend / logout in one
//     tab is mirrored to the others so an idle background tab can't expire a
//     session the user is actively using in another tab.
//
//   * Notebook activity. notebook.js dispatches `chickadee:activity` on the
//     parent window for keystrokes inside the JupyterLite iframe (whose events
//     don't otherwise reach us), so a student typing in the editor stays
//     signed in.
//
// Ceilings come from <meta name="session-idle-timeout-seconds"> and
// <meta name="session-idle-warning-seconds">, kept in sync with the server via
// the #sessionIdleTimeoutSeconds() / #sessionIdleWarningSeconds() Leaf tags. A
// timeout of 0 leaves the watchdog dormant.

(function () {
    'use strict';

    function metaInt(name) {
        var el = document.querySelector('meta[name="' + name + '"]');
        return el ? parseInt(el.getAttribute('content'), 10) || 0 : 0;
    }

    var timeoutSeconds = metaInt('session-idle-timeout-seconds');
    if (!timeoutSeconds || timeoutSeconds <= 0) return;

    var logoutForm = document.querySelector('form[action="/logout"]');
    if (!logoutForm) return;

    var timeoutMs = timeoutSeconds * 1000;
    var warningSeconds = metaInt('session-idle-warning-seconds');
    if (warningSeconds < 0) warningSeconds = 0;
    if (warningSeconds >= timeoutSeconds) warningSeconds = Math.max(0, timeoutSeconds - 5);
    var warningMs = warningSeconds * 1000;

    var lastActivity = Date.now();
    var loggingOut = false;
    var warningShown = false;

    // Cross-tab channel (graceful no-op where unsupported).
    var channel = null;
    try {
        channel = ('BroadcastChannel' in window) ? new BroadcastChannel('chickadee-session') : null;
    } catch (_) {
        channel = null;
    }

    function deadline() {
        return lastActivity + timeoutMs;
    }

    function csrfToken() {
        var el = document.querySelector('meta[name="csrf-token"]');
        return el ? el.getAttribute('content') : '';
    }

    // --- activity ---------------------------------------------------------

    var lastBroadcast = 0;
    function broadcastActivity() {
        if (!channel) return;
        var now = Date.now();
        // Throttle chatter: at most one ping every 30 s of activity.
        if (now - lastBroadcast < 30000) return;
        lastBroadcast = now;
        try {
            channel.postMessage({ type: 'extend', deadline: deadline() });
        } catch (_) {
            // ignore
        }
    }

    // Reset the idle clock. `fromRemote` avoids a broadcast echo loop.
    function markActive(fromRemote) {
        if (loggingOut) return;
        // Once the modal is up, only an explicit "Stay signed in" (or a remote
        // extend from another tab) revives the session — not passive drift.
        if (warningShown && !fromRemote) return;
        lastActivity = Date.now();
        if (warningShown) hideWarning();
        if (!fromRemote) broadcastActivity();
    }

    var activityEvents = ['mousedown', 'keydown', 'scroll', 'touchstart', 'wheel'];
    activityEvents.forEach(function (name) {
        window.addEventListener(name, function () { markActive(false); }, { passive: true });
    });
    // Bridged activity from the JupyterLite notebook iframe (see notebook.js).
    window.addEventListener('chickadee:activity', function () { markActive(false); });

    if (channel) {
        channel.onmessage = function (e) {
            var msg = e && e.data;
            if (!msg) return;
            if (msg.type === 'logout') {
                navigateToTimeoutLogin();
            } else if (msg.type === 'extend') {
                var remoteActivity = (msg.deadline || Date.now()) - timeoutMs;
                if (remoteActivity > lastActivity) lastActivity = remoteActivity;
                if (warningShown) hideWarning();
            }
        };
    }

    // --- warning modal ----------------------------------------------------

    var overlay = null;
    var countdownEl = null;
    var lastFocused = null;

    function buildModal() {
        if (overlay) return;

        var style = document.createElement('style');
        style.textContent = [
            '.cd-idle-overlay{position:fixed;inset:0;z-index:2147483647;display:flex;',
            'align-items:center;justify-content:center;background:rgba(0,0,0,.55);}',
            '.cd-idle-card{max-width:26rem;width:calc(100% - 2rem);background:#fff;color:#1a1a1a;',
            'border-radius:.6rem;padding:1.5rem 1.6rem;box-shadow:0 10px 40px rgba(0,0,0,.35);',
            'font-family:system-ui,-apple-system,sans-serif;line-height:1.45;}',
            '.cd-idle-card h2{margin:0 0 .5rem;font-size:1.15rem;}',
            '.cd-idle-card p{margin:.25rem 0 1rem;}',
            '.cd-idle-count{font-variant-numeric:tabular-nums;font-weight:700;}',
            '.cd-idle-actions{display:flex;gap:.6rem;justify-content:flex-end;flex-wrap:wrap;}',
            '.cd-idle-btn{font:inherit;padding:.5rem 1rem;border-radius:.4rem;cursor:pointer;border:1px solid transparent;}',
            '.cd-idle-stay{background:#1b6ef3;color:#fff;}',
            '.cd-idle-stay:hover{background:#1559c9;}',
            '.cd-idle-out{background:transparent;color:inherit;border-color:currentColor;opacity:.8;}',
            '@media (prefers-color-scheme:dark){.cd-idle-card{background:#23272e;color:#f0f0f0;}}'
        ].join('');
        document.head.appendChild(style);

        overlay = document.createElement('div');
        overlay.className = 'cd-idle-overlay';
        overlay.setAttribute('hidden', '');

        var card = document.createElement('div');
        card.className = 'cd-idle-card';
        card.setAttribute('role', 'alertdialog');
        card.setAttribute('aria-modal', 'true');
        card.setAttribute('aria-labelledby', 'cd-idle-title');
        card.setAttribute('aria-describedby', 'cd-idle-desc');

        var h2 = document.createElement('h2');
        h2.id = 'cd-idle-title';
        h2.textContent = 'Still there?';

        var p = document.createElement('p');
        p.id = 'cd-idle-desc';
        p.appendChild(document.createTextNode("You'll be signed out for inactivity in "));
        countdownEl = document.createElement('span');
        countdownEl.className = 'cd-idle-count';
        countdownEl.setAttribute('aria-hidden', 'true');
        p.appendChild(countdownEl);
        p.appendChild(document.createTextNode('.'));

        var actions = document.createElement('div');
        actions.className = 'cd-idle-actions';

        var outBtn = document.createElement('button');
        outBtn.type = 'button';
        outBtn.className = 'cd-idle-btn cd-idle-out';
        outBtn.textContent = 'Log out now';
        outBtn.addEventListener('click', function () { expire(); });

        var stayBtn = document.createElement('button');
        stayBtn.type = 'button';
        stayBtn.className = 'cd-idle-btn cd-idle-stay';
        stayBtn.textContent = 'Stay signed in';
        stayBtn.addEventListener('click', staySignedIn);

        actions.appendChild(outBtn);
        actions.appendChild(stayBtn);
        card.appendChild(h2);
        card.appendChild(p);
        card.appendChild(actions);
        overlay.appendChild(card);
        document.body.appendChild(overlay);

        // Keep focus inside the dialog; Esc behaves as "stay signed in".
        overlay.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') {
                e.preventDefault();
                staySignedIn();
            } else if (e.key === 'Tab') {
                e.preventDefault();
                stayBtn.focus();
            }
        });

        overlay._stayBtn = stayBtn;
    }

    function showWarning() {
        if (warningShown || loggingOut) return;
        buildModal();
        warningShown = true;
        lastFocused = document.activeElement;
        overlay.removeAttribute('hidden');
        updateCountdown();
        if (overlay._stayBtn) overlay._stayBtn.focus();
    }

    function hideWarning() {
        if (!warningShown) return;
        warningShown = false;
        if (overlay) overlay.setAttribute('hidden', '');
        if (lastFocused && typeof lastFocused.focus === 'function') {
            try { lastFocused.focus(); } catch (_) { /* ignore */ }
        }
    }

    function updateCountdown() {
        if (!warningShown || !countdownEl) return;
        var remaining = Math.max(0, Math.ceil((deadline() - Date.now()) / 1000));
        var mins = Math.floor(remaining / 60);
        var secs = remaining % 60;
        countdownEl.textContent = mins > 0
            ? (mins + ':' + (secs < 10 ? '0' : '') + secs)
            : (secs + ' second' + (secs === 1 ? '' : 's'));
    }

    function staySignedIn() {
        if (loggingOut) return;
        var token = csrfToken();
        fetch('/session/keepalive', {
            method: 'POST',
            headers: { 'x-csrf-token': token, 'accept': 'application/json' },
            redirect: 'manual'
        }).then(function (res) {
            // A 302 (manual redirect surfaces as opaqueredirect / !ok) means the
            // server already expired us mid-warning — finish the logout.
            if (!res || !res.ok) {
                expire();
                return;
            }
            return res.json().then(function (body) {
                var secs = body && body.secondsRemaining ? body.secondsRemaining : timeoutSeconds;
                lastActivity = Date.now() - Math.max(0, timeoutSeconds - secs) * 1000;
                hideWarning();
                lastBroadcast = 0;
                broadcastActivity();
            }).catch(function () {
                lastActivity = Date.now();
                hideWarning();
            });
        }).catch(function () {
            // Network error — be conservative and sign out.
            expire();
        });
    }

    // --- logout -----------------------------------------------------------

    function navigateToTimeoutLogin() {
        if (loggingOut) return;
        loggingOut = true;
        window.location.href = '/login?error=timeout';
    }

    async function expire() {
        if (loggingOut) return;
        loggingOut = true;

        if (channel) {
            try { channel.postMessage({ type: 'logout' }); } catch (_) { /* ignore */ }
        }

        if (overlay) {
            var desc = overlay.querySelector('#cd-idle-desc');
            if (desc) desc.textContent = 'Signing you out…';
        }

        // Best-effort: persist any open notebook before the session ends, so a
        // student who walked away doesn't lose unsaved cells. notebook.js
        // exposes this only on the notebook editor page; elsewhere it's absent.
        if (typeof window.chickadeeSaveNotebook === 'function') {
            try {
                await Promise.race([
                    window.chickadeeSaveNotebook(),
                    new Promise(function (resolve) { setTimeout(resolve, 3000); })
                ]);
            } catch (_) {
                // Saving is best-effort; never block the sign-out on it.
            }
        }

        // Route through the real logout form so CSRF + server-side SSO logout
        // run. `?reason=timeout` lands on the inactivity message.
        try {
            logoutForm.setAttribute('action', '/logout?reason=timeout');
            if (typeof logoutForm.requestSubmit === 'function') {
                logoutForm.requestSubmit();
            } else {
                logoutForm.submit();
            }
        } catch (_) {
            window.location.href = '/login?error=timeout';
        }
    }

    // --- tick / re-evaluation ---------------------------------------------

    function evaluate() {
        if (loggingOut) return;
        var now = Date.now();
        if (now >= deadline()) {
            expire();
        } else if (warningMs > 0 && now >= deadline() - warningMs) {
            showWarning();
            updateCountdown();
        } else if (warningShown) {
            // Clock was pushed back (remote extend); countdown still ticking.
            updateCountdown();
        }
    }

    // Foreground heartbeat (frozen while backgrounded — that's fine).
    setInterval(evaluate, 1000);

    // Load-bearing: catch a tab that was hidden past the ceiling the instant
    // it's shown again, so the user never has to click a link first.
    document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') evaluate();
    });
    window.addEventListener('focus', evaluate);
    window.addEventListener('pageshow', evaluate);
}());
