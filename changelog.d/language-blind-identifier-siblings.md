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

  Two name kinds keep the `[A-Za-z_][A-Za-z0-9_]*` rule, and the comments around
  them now say why in terms that are not Python's: global/section **input**
  names, referenced from a notebook as `{{name}}`, and family **variables**,
  referenced from an arg cell as `$name`. That character set is the
  cross-language subset, pinned by the weakest emitter rather than by Python's
  semantics — R backticks an awkward name and Lua/Octave mangle one, but the
  Python preamble writes `name = _ck["name"]` with no emitter, so a hyphen is a
  syntax error. Widening them is therefore not "make it language-aware" (a
  placeholder is replaced by a literal value and reaches no runtime); it is
  giving Python an emitter like the other four have, then widening the two
  reference parsers with it.
