### Fixed

- **Empty states across 22 pages now render.** LeafKit has no property
  resolution, so `#if(rows.isEmpty)` on an array resolved to nil and never
  fired, while its negation always did. Enrollment with no open courses showed
  the enrollment form; submission history and five admin pages showed a
  header-only table promising rows and listing none; an "Auto-detected:" note,
  a Section picker and empty badge containers rendered with nothing in them.
  All 33 sites now use the `count()` tag, which resolves arrays properly.
- **The idiom is now blocked.** `scripts/check-leaf-semantics.sh` fails on
  Swift property access in a Leaf tag parameter, with a `check-guards.sh`
  fixture proving it still catches its own defect, and
  `LeafEmptyStateRenderTests` asserts the empty copy appears rather than merely
  that the page returns 200.
- **The new course page shows its assignment count again.** `assignmentCount`
  was a computed property, and Swift's synthesized `Encodable` encodes stored
  properties only — so it never reached the Leaf context and the heading read
  "Assignments ()" above a working "Enrolled students (0)". It renders through
  `count()` now.
