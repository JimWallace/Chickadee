### Changed

- **Docs and comments across the extraction and capability surfaces now name all
  seven languages** rather than the two or three that existed when they were
  written. The operationally important one is
  `docs/runner-capability-profiles.md`, which listed three probed languages out
  of eight — the page an operator reads to answer "why doesn't this runner
  advertise `racket`".
- **The unreachable `.python` arm in the marker-extractor switch is a trap
  rather than a silent alias for R.** It was folded in with `.r`, so a later
  cleanup that merged Python into that group would have extracted every Python
  notebook as R.
