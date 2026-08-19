### Added

- **The `.0`-suffix rule every literal renderer shares is now pinned once, in a
  table.** A finite double must render as something the target language reads
  back as a float, and each of the seven renderers implements that the same way:
  `(s.contains(".") || s.contains("e") || …) ? s : s + ".0"`. Every suite tested
  the first term — `2.0` is the obvious case — and a search for e-notation across
  all five existing literal suites returned zero hits, so the second term was
  covered nowhere. The 2026-08-19 sweep found the identical hole in four
  renderers, which is what copying a working renderer *and its tests* produces.
  `JSONValueDoubleFormattingTests` covers all seven from one table, so a new
  language is one line and cannot inherit the gap from a neighbour; it also
  asserts the property underneath the rule, that every rendered finite double
  reads back as itself.
- **`pythonLiteral` has a CoreTests file**, chiefly for its object-key sort. It
  was the only renderer without one — its assertions live in `APITests`, which
  the sweep skips — which is why the sweep flagged a sort that had already been
  pinned for Racket and Java. Key order is not cosmetic: generated filenames
  embed a `spec_hash` of the rendered bytes, so an unstable order makes a pattern
  family look edited on every save.
