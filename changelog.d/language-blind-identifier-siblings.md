### Fixed

- **Pattern-family parameter names and `variable_equality` case variables are
  now checked against the assignment's language, not Python's.** The previous
  release made a family's `functionName` language-aware and stopped there,
  leaving sibling names in the same file still validated with
  `isValidPythonIdentifier` on every assignment. A Racket author could finally
  save `bmi-category` as the target and was then refused on the parameter
  `bmi-value`, with a message naming Python. Both now use
  `isValidIdentifier(_:language:)` — which already existed, `private`, in
  `NotebookCheckKindHandler.swift`: it was written for notebook checks and never
  shared, so nothing was missing, it was out of reach. The refusal names the
  assignment's language.

  Two name kinds are deliberately left on Python's grammar, because each is
  REFERENCED by a Python-shaped parser and widening one alone converts a clear
  refusal into a silent misread: global/section **input** names, referenced from
  starter notebooks as `{{name}}`, and family **variables**, referenced from an
  arg cell as `$name`. In both cases the reference would stop matching and fall
  through as literal text — a wrong expected value in a generated test, or an
  unsubstituted placeholder in every student's notebook, reported nowhere. Each
  is one coupled change with its parser, not a validation tweak.
