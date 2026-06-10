### Fixed

- **Slow editor boots no longer aborted by the locked-path enforcement.** On
  the student notebook page, `enforceLockedNotebookPath()` treated an iframe
  that hadn't committed its first document yet (`location.href` still
  `about:blank`) as "student navigated away" and force-reset `frame.src` —
  with only a 1-second debounce against the 1.5-second enforcement interval.
  Any boot where the JupyterLite `index.html` took longer than ~1.5s to commit
  (slow connection, or the server busy with a class-wide 8am rush) was aborted
  and restarted indefinitely, so the shell never appeared and the phase-1
  watchdog fired `watchdog_timeout` on a healthy-but-slow boot — the students
  behind the "Students With Browser Errors" dashboard card. Enforcement now
  waits for the first committed document before acting, gives a forced reset a
  generous window to commit (cleared by the iframe load event) before forcing
  another, and `mountEditor()` no longer re-assigns the identical `src` the
  template already rendered (which aborted and restarted the eager initial
  load on every page view).

### Changed

- **Vendored editor assets skip the session middleware chain and the
  content-hashed JupyterLite bundle is cached immutably.** A JupyterLite boot
  fetches hundreds of static files, each of which previously paid a Fluent
  session lookup before FileMiddleware served it — the load that drives
  editor `index.html` latency up during a class-wide rush. The new
  `EditorAssetFastPathMiddleware` serves a strict whitelist of vendored trees
  (`/jupyterlite/build`, `/jupyterlite/extensions`, `/pyodide`, `/vendor`)
  ahead of the session chain; the auth-guarded `/jupyterlite/…/files/users/`
  paths are deliberately not on the fast path and still ride the full chain
  (pinned by a regression test). Webpack content-hashed bundle filenames get
  `Cache-Control: public, max-age=31536000, immutable`, eliminating the
  per-boot revalidation storm; unhashed names and all of `/pyodide` +
  `/vendor` keep ETag revalidation because re-vendoring rewrites those bytes
  in place under stable names.
