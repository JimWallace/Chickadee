### Fixed

- **A suite save no longer rewrites a "None" assignment's language to Python.**
  Every suite save runs through the pattern-family apply path, which recorded
  whatever language it resolved — and that resolution ended in a Python
  fallback. Reordering two shell scripts on an assignment whose author chose
  "None" therefore declared it Python, silently and stickily. The apply path now
  carries the declaration as an optional and persists it unchanged.
- **The new-assignment page no longer erases the language it just asked for.**
  The manifest builder writes a fresh object, so the draft's suite actions and
  the publish rebuild dropped both `language` and `languageDeclared` on the
  floor — the author picked R, uploaded a suite, and the choice was gone. Both
  fields are threaded through every rebuild.
- **`update_solution` no longer checks a solution filename against Python's
  extensions on an assignment that declares no language**, which accepted
  `solution.py` and rejected everything else for a reason nothing in the
  assignment supported.

### Changed

- **Authoring refuses, with a message naming the fix, where it used to guess
  Python.** Adding a pattern family or notebook check, and storing a per-student
  `=` expression, now require the assignment to declare a language: a generated
  test and an expression are both source code, and an assignment set to "None"
  has no syntax to write them in. Saves that generate nothing — reordering raw
  scripts, editing literal variables — are unaffected, and nothing on the
  grading path refuses: an instructor can fix a missing declaration from the
  dropdown, a student cannot.
- **`docs/language-declaration.md`** records the rule the multi-language arc
  landed on (every assignment declares its language; nothing infers one), the
  doors that enforce it, and a per-site table of the remaining Python fallbacks
  split by whether they sit on an authoring path or a grading one.
