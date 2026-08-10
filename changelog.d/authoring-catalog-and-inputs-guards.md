### Fixed

- **The per-student inputs filename is generated for the browser, not
  hand-written.** `Public/browser-runner.js` chose between four literal
  filenames in an if/else chain whose final branch wrote Python's. That chain
  had already shipped the bug it invites: a browser-graded Lua assignment took
  the Python branch and wrote `_ck_inputs.py` while the Lua runtime read
  `_ck_inputs.lua`, so every per-student value went missing — silently, with no
  error and wrong marks. `scripts/generate-js-constants.sh` now emits
  `INPUTS_FILE_NAMES` from `LanguageDescriptor.inputsFileName`, so the filename
  is machine-written and CI fails when it goes stale.

  The renderer table stays hand-written — the four writers live in the browser's
  own `*-grading-shared.js` modules and have no Swift counterpart to derive from
  — and `BrowserInputsWriterCoverageTests` pins it to exactly the languages with
  an editor kernel. A fifth kernel language missing from it is what would make
  the Python fallback reachable again.

### Added

- **A coverage guard on the "+ Add Test" catalog**
  (`TestEditorCatalogCoverageTests`). The menu in `Public/test-editor-modal.js`
  is a hand-written list, one entry per `PatternKind` and per
  `NotebookCheckKind`, and nothing made it cover them. A ninth pattern kind
  would land with a renderer in six languages, a validator, an MCP schema and
  execution tests — every one of which fails loudly if missing — and then simply
  not appear in the menu: the server accepts it, an agent can author it, and the
  instructor in the editor cannot reach it.

  `AuthoringLanguageFactsTests` already pinned that the menu's per-language
  availability agrees with the save-time validator; this pins the prior question
  that one assumes, that the kind is in the menu at all. It also fails on an
  entry the server would refuse, and on one with no description.
