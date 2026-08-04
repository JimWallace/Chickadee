### Changed

- **The assignment workbench is now a single document.** The edit page and the
  notebook editor were composed as two same-origin iframes; they are now
  rendered inline by one template, each bound to its own sub-context. The
  wrapper frames are gone and the only remaining `<iframe>` is the JupyterLite
  editor itself. Writes refresh the edit half by swapping its DOM rather than
  reloading, so a save, a suite-section rename, or a support-file upload no
  longer costs the live Pyodide kernel a 10–30s reboot. Switching between the
  starter and the solution stays a full navigation — the kernel restarts either
  way — and is guarded by an unsaved-changes prompt.

### Fixed

- **Leaf partial decomposition was never blocked by a LeafKit parser bug.** The
  long-standing rule of "at most one inline `extend(...)` include per template"
  traced to a misdiagnosis: what actually fails is the literal tag text
  appearing in template *prose*, including inside HTML comments, which Leaf's
  lexer reads as a real tag with no parameters. Multiple includes, and the
  sub-context form, work fine. `CLAUDE.md` is corrected.

- **An assignment with no starter notebook no longer breaks its workbench.**
  Inlining the notebook made a missing one able to fail the whole authoring
  page; the pane now degrades to a placeholder and the edit half stays usable,
  which is where a starter gets uploaded in the first place.
