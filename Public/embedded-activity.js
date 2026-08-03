// Public/embedded-activity.js
//
// Activity forwarder for pages rendered *into a pane* of the assignment
// workbench (`workbench.leaf`).  Loaded by base.leaf only when the page context
// carries `embedded`.
//
// Why this exists:
//
//   `idle-logout.js` is a client-side inactivity watchdog — institutional
//   policy requires signing an idle user out after a fixed period, and the
//   server can't do it alone because a user sitting on a page makes no
//   requests.  It measures interaction with *its own document*.
//
//   The workbench composes two existing pages as same-origin iframes, so every
//   keystroke an author makes lands in a pane document, not in the shell.  The
//   shell holds the only watchdog (it is the only one of the three documents
//   with a nav, and `idle-logout.js` bails out without the nav's logout form),
//   and left to itself it would see a completely idle document and sign the
//   author out roughly 30 minutes into an editing session.
//
//   So each pane forwards a throttled "someone is here" ping up to the shell,
//   which re-dispatches it as `chickadee:activity` — the event `idle-logout.js`
//   already listens for on behalf of the JupyterLite iframe.
//
// Note this is about the *client-side* watchdog only.  Server-side session life
// is separately kept alive by notebook.js, which POSTs /session/keepalive on
// editor activity; that runs unchanged inside the pane.
//
// Deliberately tiny and dependency-free: it must not assume ChickadeeUI, and it
// must be a no-op when the page is somehow loaded top-level (a stale bookmark
// to a `?embedded=1` URL), which is what the `window.parent === window` guard
// below is for.

(function () {
    'use strict';

    // Not in a frame — nothing to forward to.  A pane URL opened directly in a
    // tab still renders; it just has no parent to notify.
    if (window.parent === window) return;

    // The watchdog is dormant when no idle ceiling is configured, so there is
    // nothing worth forwarding.  Mirrors idle-logout.js's own early return.
    var meta = document.querySelector('meta[name="session-idle-timeout-seconds"]');
    var timeoutSeconds = meta ? parseInt(meta.getAttribute('content'), 10) || 0 : 0;
    if (timeoutSeconds <= 0) return;

    // Leading-edge throttle.  The shell only needs to know activity happened
    // recently, not how many keystrokes there were, and postMessage on every
    // keydown would be pure overhead in a document whose whole job is to host a
    // text editor.  10s is far below any plausible idle ceiling.
    var THROTTLE_MS = 10 * 1000;
    var lastSent = 0;

    function forwardActivity() {
        var now = Date.now();
        if (now - lastSent < THROTTLE_MS) return;
        lastSent = now;
        try {
            // Explicit target origin rather than '*': this message is only ever
            // meant for a Chickadee shell on the same origin, and '*' would leak
            // the fact that someone is typing to any document that managed to
            // frame this page.
            window.parent.postMessage(
                { source: 'chickadee', type: 'activity' },
                window.location.origin
            );
        } catch (_) {
            // Cross-origin parent, or a parent that went away mid-navigation.
            // Nothing to do — the shell simply keeps its own idle timer.
        }
    }

    ['keydown', 'pointerdown', 'wheel'].forEach(function (name) {
        window.addEventListener(name, forwardActivity, { passive: true, capture: true });
    });

    // notebook.js raises this on the pane window for keystrokes that happen
    // inside the *JupyterLite* iframe, whose own events never reach us.  Without
    // this line, an author typing in notebook cells — the single most likely way
    // to spend 30 minutes in the workbench — would look idle to the shell.
    window.addEventListener('chickadee:activity', forwardActivity);
}());
