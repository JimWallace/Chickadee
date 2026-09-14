// Closes the stray editor tab served by JupyterLiteAppIndexMiddleware.
//
// Notebook 7 opens a document in a new tab with `window.open`, landing on the
// bare `/jupyterlite/<app>` directory URL.  The middleware answers it with a
// tiny page rather than a second full editor, and this closes the tab.  A
// script-opened tab is allowed to close itself; if a browser refuses, the
// page's own sentence tells the reader what to do.
try {
    window.close();
} catch (e) {
    /* self-close may be blocked; the page's message covers it */
}
