### Added

- **Every guard is now proved to fail on its own defect.** The house rule —
  "a check never seen to fail is not a check" — was the one discipline here
  with nothing enforcing it, and the cost is on the record four times: a
  regression test matching a wiring string after the wiring went dead, the
  repaint probe's filter assertion passing against a dead poll, the S5 guard
  matching its own documentation, and a hover-budget test that passed three
  times while exercising nothing. `scripts/check-guards.sh` runs each fixture
  in `scripts/guard-fixtures/` — a guard, a defect that guard exists to catch,
  and the message it must produce — and **fails the build if the guard
  passes**. 18 fixtures cover the token, name and idiom layers: raw colours,
  off-scale font sizes, radii and spacing, undefined and hardcoded-fallback
  CSS vars, unresolved classes, inline styles in templates and in JS-built
  HTML, native `alert()` in both, inline `<script>`, native `confirm()`,
  icon geometry outside the sprite, retired button modifiers, page blocks
  re-defining global selectors, page-local sorters, and JS-written colour.
  Its own runner refuses an empty fixture set, checks each guard is green on
  the clean tree before trusting any result, asserts the *expected message*
  rather than just a non-zero exit (so a defect tripping a neighbouring rule
  is not mistaken for coverage), and restores every file it touches on all
  exit paths. Runs as its own CI job and joins the merge gate.
