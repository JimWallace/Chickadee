### Added

- **Assignment workbench — the edit page and the notebook editor, side by side.**
  A new instructor surface at `/instructor/:assignmentID/workbench` puts the
  assignment editor in a left pane and the embedded JupyterLite editor in a
  right pane, with a tab strip that switches the notebook pane between the
  starter notebook and the reference solution. Authors can read and change
  global inputs, section variables, suite entries and deadlines while a Pyodide
  kernel boots or a validation run finishes, instead of paying a full editor
  cold boot on every hop between the two pages. Reached from a "Workbench"
  button on the edit page; the standalone `/edit` and
  `/testsetups/:id/notebook` pages are unchanged and remain the default.

  The shell renders no assignment content of its own — it composes the two
  existing pages as same-origin iframes, so the suite editor, inputs editors and
  `notebook.js` all run unmodified. The solution pane stays unmounted until its
  tab is first selected, then stays warm, so switching costs one kernel boot
  rather than one per switch; a device reporting low memory keeps a single
  kernel and reboots on switch instead. The splitter is drag- and
  keyboard-operable and clamps so the notebook pane can never fall under the
  width at which it would replace the editor with its "open on a larger screen"
  notice; below a viewport that can hold both panes honestly, the layout falls
  back to one pane at a time.

### Fixed

- **Cross-origin isolation now covers the whole editor frame chain.** Isolation
  is a property of every ancestor, so nesting the notebook page inside another
  page requires the outer documents to carry `COOP`/`COEP` as well. Without it
  the editor iframe would lose `SharedArrayBuffer` and silently fall back to the
  service-worker kernel transport on Chrome and Firefox — and, under
  `require-corp`, the sibling pane would have been refused outright. The
  workbench routes are isolated on the same terms as the notebook page,
  including the WebKit exemption that keeps Safari on its comlink path. Plain
  `/instructor/*` pages are unaffected.
