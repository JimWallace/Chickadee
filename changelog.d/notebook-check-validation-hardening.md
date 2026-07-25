### Fixed

- **Notebook-check validation hardening.** `cell_contains` regex validation no
  longer rejects an escaped `\(`, a parenthesis inside a `[...]` character
  class, or a literal trailing `\\` as unbalanced/dangling — it tracks escape
  state and character-class nesting instead of counting raw parentheses (this
  affected Python authors too). Name fields (`variable`, function names) on an R
  assignment now accept idiomatic R names such as `my.df` via a new
  `isValidRIdentifier`, instead of being held to Python's identifier rules.
