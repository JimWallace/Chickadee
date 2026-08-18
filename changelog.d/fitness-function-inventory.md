### Added

- **`docs/fitness-functions.md`** — an inventory of the automated checks that
  hold the architecture, sorted by the Building Evolutionary Architectures
  taxonomy (atomic vs holistic, triggered vs continual). No new machinery: the
  point is that nothing answered "what governs this?" in one place, and the
  taxonomy makes one real gap visible. `RouteAuthorizationMatrixTests` walks
  the **live route table**, so routes are discovered — but it crosses every
  route with exactly two personas, and `.ta` appears nowhere in it, leaving the
  TA boundary on eight hand-written spot tests. A new instructor-only route
  that forgets its floor passes both. That is the "enumerated rather than
  discovered, fails open" shape the language work was built to escape, on the
  dimension where the failure mode is cross-course access rather than a
  mis-rendered test.
