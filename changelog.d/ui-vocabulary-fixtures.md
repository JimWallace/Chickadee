### Added

- **The UI-vocabulary guard now ships with its fixtures.** Its three rules —
  the catalog ratchet, the affordance registry (`cursor` and
  `text-decoration`), and the 20-word hover-text cap — each gain a fixture in
  `scripts/guard-fixtures/`, so each is now *seen to fail* on the defect it
  exists to catch. The four defects are the ones that actually shipped in
  0.5.136: a global component the rulebook does not name, `cursor: help`, a
  dotted underline, and a paragraph in a `title`. The guard and the self-test
  harness landed in separate PRs and could only meet on `main`; this is the
  rule those PRs established — a guard ships with its fixture — paying its own
  tax. 22 fixtures total.
