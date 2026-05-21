// Public/idle-logout.js
//
// Client-side inactivity watchdog. Required by the institutional security
// policy: an authenticated user who stops interacting must be signed out and
// returned to the login page after a fixed idle period (default 30 minutes).
//
// The server already enforces this on the *next* request via
// SessionIdleTimeoutMiddleware, but a user who simply sits on a page makes no
// requests, so the server never gets a chance to redirect them. This script
// closes that gap: it watches for user input, and once the idle ceiling is
// reached it (best-effort) saves any open notebook, then submits the logout
// form so the full server-side logout runs (session cleared, SSO session
// terminated) and the browser lands on /login.
//
// The ceiling is read from <meta name="session-idle-timeout-seconds">, kept in
// sync with the server via the #sessionIdleTimeoutSeconds() Leaf tag. A value
// of 0 (gate disabled) leaves the watchdog dormant.

(function () {
    'use strict';

    var meta = document.querySelector('meta[name="session-idle-timeout-seconds"]');
    var timeoutSeconds = meta ? parseInt(meta.getAttribute('content'), 10) : 0;
    if (!timeoutSeconds || timeoutSeconds <= 0) return;

    var logoutForm = document.querySelector('form[action="/logout"]');
    if (!logoutForm) return;

    var timeoutMs = timeoutSeconds * 1000;
    var lastActivity = Date.now();
    var loggingOut = false;

    // Cheap activity tracking: just stamp the time. We avoid resetting a
    // per-event timer (which would fire on every mousemove) and instead poll
    // on a coarse interval, comparing against the last stamp. Polling also
    // survives a tab being backgrounded/suspended better than a single long
    // setTimeout.
    function markActive() {
        lastActivity = Date.now();
    }

    var activityEvents = ['mousedown', 'mousemove', 'keydown', 'scroll', 'touchstart', 'click', 'wheel'];
    activityEvents.forEach(function (name) {
        window.addEventListener(name, markActive, { passive: true });
    });

    async function expire() {
        if (loggingOut) return;
        loggingOut = true;

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
        // run. `?reason=timeout` tells the server to land on the inactivity
        // message rather than the neutral "signed out" one.
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

    // Check four times per minute; precision to ~15 s is plenty for a 30 min
    // ceiling and keeps the timer effectively free.
    setInterval(function () {
        if (loggingOut) return;
        if (Date.now() - lastActivity >= timeoutMs) {
            expire();
        }
    }, 15000);
}());
