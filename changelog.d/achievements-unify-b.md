### Changed

- **Achievements unification (B): one typed `/achievements` endpoint.**
  `GET`/`PUT /instructor/:id/achievements` now round-trips the whole typed
  `Achievement` list — every kind (class goals, threshold/test badges, class
  records, and the per-submission kinds) — via an `achievements` field with
  per-kind validation. The legacy `goals` shape still works (replaces only the
  class-goal subset), so the existing Class Goals card is unaffected until the
  unified editor table lands.
