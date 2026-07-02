### Added

- **Accessibility ratchet (#1137).** The visual-regression CI job now also
  runs an axe-core scan (`Tools/visual-regression/a11y.mjs`) over the six
  key pages in both colour schemes. Critical/serious violations fail CI
  outright; moderate/minor are a shrink-only count ratchet against
  `a11y-baseline.json`. Guards the post-phase-8 AODA work against
  regression — a new template with a missing label or scheme-specific
  contrast bug now fails on its introducing PR.
