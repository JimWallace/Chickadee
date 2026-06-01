### Fixed

- **Pattern-family arg cells can reference assignment-scope global inputs.** A
  `$name` reference to a Global Input (the worked example in `docs/inputs.md`)
  was rejected by the pattern-family validator with "references unknown
  variable", even though the renderer puts global inputs in scope alongside
  section and family variables. The validator now accepts `$global` references,
  matching what actually renders.
