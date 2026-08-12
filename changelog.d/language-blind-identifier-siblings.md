### Fixed

- **Pattern-family parameter, variable and `variable_equality` names are now
  checked against the assignment's language, not Python's.** The previous
  release made a family's `functionName` language-aware and stopped there,
  leaving three sibling names in the same file still validated with
  `isValidPythonIdentifier` on every assignment. A Racket author could finally
  save `bmi-category` as the target and was then refused on the parameter
  `bmi-value`, with a message naming Python. All three now use
  `isValidIdentifier(_:language:)` — which already existed, `private`, in
  `NotebookCheckKindHandler.swift`: it was written for notebook checks and never
  shared, so nothing was missing, it was out of reach. The refusal names the
  assignment's language.

  Global and section **input** names are deliberately unchanged and remain on
  Python's grammar. They are referenced from starter notebooks as `{{name}}`,
  and `NotebookSubstitution.placeholderRegex` hardcodes `[A-Za-z_][A-Za-z0-9_]*`
  — widening the name check alone would let an author save `bmi-value` and then
  silently leave `{{bmi-value}}` as literal text in every student's notebook.
  The two have to move together.
