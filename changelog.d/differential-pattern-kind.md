### Added

- **A ninth pattern-family kind: `differential`.** It grades a submission
  against an instructor-written reference implementation instead of a tabulated
  expected value — each case supplies only inputs, and the expected value is
  whatever the reference returns at grade time. It renders and executes in all
  six languages.

  This was the one thing the retired custom-script templates could do that no
  kind could. It earns its place where enumerating expected values is the hard
  part: a function over a large or awkward input space, or one whose right
  answer is easier to *write* than to *tabulate*. Per-student `$name` argument
  refs work, so the reference computes each student's expected value rather than
  the author tabulating one per student.

  Two things to know before reaching for it, both stated in the kind's own
  documentation and in the MCP tool description:

  The reference is rendered into the generated test, so on a **browser-graded**
  assignment it reaches the student's browser along with every other test script
  — browser grading runs the suite locally, so it must. Chickadee does not
  refuse or warn: whether a reference implementation is a secret is the
  instructor's judgement, and for many assignments it plainly is not. Worker
  grading is the answer when it is.

  And it grades *agreement*, not correctness. A wrong reference makes a wrong
  test that passes for whoever reproduces the same mistake.

  A reference that raises is reported as `errored`, not `failed` — a student
  cannot make it raise except through inputs the instructor chose, so blaming
  their submission would send them to debug the wrong code. In C++ the reference
  is compiled with the test, so one that does not compile is a build failure
  instead, which lands on the instructor at validation.

### Fixed

- **The MCP surface no longer holds a hand-typed list of pattern kinds.** Three
  places did — the `initialize` instructions, the `create_pattern_family`
  description, and that tool's JSON `enum` — and adding a kind made all three
  wrong at once, telling an agent the kind does not exist while
  `get_server_info`, which derives its list from `allCases`, reported that it
  does. `MCPPatternKindProse` now renders all three from `PatternKind.allCases`
  behind an exhaustive switch, so a tenth kind does not compile until it says
  what it is and then needs no copy edits at all. The sibling of
  `MCPLanguageProse`, for the same reason and after the same finding.

- **A family's fields no longer depend on being remembered.** Two paths rebuilt
  a `PatternFamily` field by field — the suite-edit path when the editor sends a
  row-level dependency, and `update_pattern_family` — and both dropped anything
  not listed. That already happened once, to `variables`: an `argVarRefs`
  reference failed validation on the next save of a family the author had not
  touched. There is now one `replacingDependsOn` copy beside the property list,
  pinned by a `Mirror`-based test that fails when any stored property does not
  survive.

- **The family editor's kind `<select>` is covered by the catalog guard**, which
  previously reached only the two lists in `test-editor-modal.js`. A kind
  missing from the template can be created from the Add Test menu but never
  switched to on an existing family — a gap that reads as "not supported yet"
  rather than as a bug.
