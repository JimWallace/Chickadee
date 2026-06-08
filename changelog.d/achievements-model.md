### Added

- **Achievements model (foundation).** A per-assignment `achievements: [Achievement]`
  manifest field (Core) — the generalized, instructor-authorable form of
  Chickadee's previously-hardcoded badge / class-achievement system. One
  `Achievement` expresses the collaborative class goal, individual badges
  (incl. First-Try Perfect), and the legacy one-holder class records, by
  `kind`. Server-evaluated and display-only; stripped from the runner-facing
  manifest like pattern families and notebook checks. Groundwork only —
  evaluation, the class-goal grade bonus, student display, and authoring land
  in follow-ups.
