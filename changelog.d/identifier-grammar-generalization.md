### Fixed

- **Every author-supplied name is now held to the assignment's own language, not
  a cross-language subset.** Global and section input names, family variables,
  parameter names and `variable_equality` case variables all now use
  `isValidIdentifier(_:language:)`, so an R author may name an input `my.df` and
  a Racket author `bmi-value`.

  Two of those could not be widened before, because the parsers that REFERENCE
  them each carried their own copy of a grammar — `{{name}}` in
  `NotebookSubstitution` and `$name` in `pattern-family-editor.js`, both matching
  `[A-Za-z_][A-Za-z0-9_]*`. A name outside that set failed as a silent misread
  rather than a refusal: `$bmi-value` fell through as a literal string (a wrong
  expected value in a generated test) and `{{my.df}}` survived into every
  student's notebook as text.

  Rather than teach those parsers the grammar, they stopped having one. Both are
  now permissive token grabs, and the ten hand-written copies of the `$name`
  regex became a single constant. Deciding whether a token is a legal name is
  the validator's job, and it already answers per language, exhaustively, with
  the compiler enforcing that a new language cannot be missed. Racket settles
  the point: its grammar is a negative rule — anything but whitespace, reader
  delimiters, a leading `#`, or something that parses as a number — which no
  character class expresses, so a per-language regex in the browser was never
  going to be correct anyway.

  The editor's inline check went permissive for the same reason: the server
  answers per language, so a fixed rule in the browser can only drift from it.

- **Reserved words are now refused in the language that reserves them.** A C++
  assignment could take an input named `template` (Python has no such keyword)
  and then render `inline const auto template = …`, which does not compile;
  likewise `class` on a Java assignment, whose inputs become `public static
  final` fields. The C++ renderer's comment already asserted these were "refused
  by the cpp validator" — the inputs path was calling Python's, so that was an
  intention rather than a fact. It is a fact now.
