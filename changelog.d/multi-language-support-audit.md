### Added

- **Architecture audit of multi-language support (`docs/multi-language-audit.md`).**
  Covers the arc from Lua's completion through Racket. Finds Racket ungradable on
  the native worker via three stacking defects — generated `.rkt` tests classify
  as unknown and run under `/bin/sh`, no Racket runtime helper is written into
  the grading workspace, and `racket --version`'s letter-led version token
  (`v8.10`) defeats the runner's version parser so no runner ever advertises the
  language — plus the upload-only coherence rule still naming C++ at three of its
  five enforcement sites. No behaviour changes; the audit is documentation only.
