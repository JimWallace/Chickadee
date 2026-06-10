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
