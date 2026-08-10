### Fixed

- **A hand-written test in Lua or Racket no longer gets a banner its interpreter
  cannot read.** The comment written above inlined global/section inputs was a
  hardcoded `#` line in every language — a comment in Python, R, Octave and
  shell, and a syntax error in the other three, where `#` is Lua's length
  operator, a Racket reader prefix and a C++ preprocessor directive. Because the
  banner is also the sentinel used to strip the previous block, re-saving
  compounded the damage instead of repairing it. `LanguageDescriptor` gained
  `lineCommentPrefix`, and a script already carrying the broken banner is
  repaired on its next save. Python, R and Octave output is byte-identical.

- **The main web authoring path no longer skips four languages when inlining
  inputs.** `PUT /suite` picked a raw script's language with a hand-written
  switch on `py`/`r` and `default: nil`, so a hand-written Lua, Octave, Racket or
  C++ test received no global or section variables — while MCP `author_script`
  and the single-script save, which resolve through
  `AssignmentLanguage(scriptExtension:)`, delivered them. All three paths now
  resolve the same way, behind one `supportsRawScriptInlining` predicate that
  declines C++ (whose graded scripts are `.sh` wrappers, so an inlined
  declaration would never be read).

- **Racket inputs land inside the module.** A `#lang` line now keeps line 1 the
  way a shebang does. This is stronger than the shebang rule it reuses: a
  `(define …)` written above `#lang` is a read error, not a formatting problem.

### Added

- **`docs/authoring-parity.md`** — what an instructor authoring in each of the
  six languages can and cannot do, which differences are defects and which are
  correct refusals (with the substrate reason for each, so they stop being
  re-litigated), and the remaining work in order.
