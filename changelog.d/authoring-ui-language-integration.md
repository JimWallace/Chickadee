### Fixed

- **The Global and Section Inputs editors read the assignment's language.**
  `inputs-editor-core.js` parsed values by Python's rules — `True`, `False`,
  `None`, and a Python-repr rewrite — on all six languages, so an R instructor
  typing the boolean true stored the *string*. These panels are where per-student
  `=` expressions are authored, and an expression is evaluated in the
  assignment's language, not Python. The scalar spellings now come from the same
  shared reader the pattern-family editor uses.
- **The "Add Test" menu no longer offers notebook-check kinds the language
  cannot save.** It listed all ten on every assignment — six a Lua author could
  not save, and every one of them on C++ or Racket, where there is no notebook to
  check at all. Unsupported kinds are disabled with their reason, derived from
  the same predicate the save-time refusal uses (issue #1290).
- **The dashboard stops offering an editor link for a language that has none.**
  The row reported the stored submission mode while gating Edit and Open-editor
  on it; it now reports `effectiveSubmissionMode`, matching `effectiveGradingMode`
  beside it. Manifest-writing sites keep the stored value.

### Changed

- **`Public/authoring-language.js`** is the one place the browser reads the
  assignment's language facts, shared by the pattern-family editor, the inputs
  editors and the test-editor modal, so "how does this language spell true" has a
  single answer.
- Student- and instructor-facing wording that named Python on every assignment:
  the in-browser kernel messages, the raw-script blurb's extension list, and the
  required-languages placeholder.
