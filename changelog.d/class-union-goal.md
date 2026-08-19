### Added

- **Class goals can grade on the UNION of what the class produced.** A new
  achievement condition signal, `itemsCovered`, counts the DISTINCT suite items
  the class has collectively passed — the collaborative bug-hunt shape, where
  every student contributes a test or two and the goal is "the class has found
  12 of the seeded bugs". Optionally scoped to one suite section, so a hunt's
  seeded variants are counted and the well-formedness gate beside them is not.
  Every other class goal counts students clearing a grade threshold; this one
  reads the accumulated coverage table.
- **The union goal has a breadth half, and it is what makes a contribution cap
  unnecessary.** `classPercent` keeps its exact sentence — the share of the
  class that must satisfy the per-student part — and for a union goal that part
  is "contributed at least one covered item". Progress is the smaller of the two
  halves, so one student finding every bug reaches full coverage and then fails
  the goal on breadth. The alternative (crediting only each student's K rarest
  items) would bound the solo hero too, and would break the sweep's determinism
  doing it.
- **The achievement snapshot records what it froze at.** `achievement_results`
  gained nullable `items_covered` / `items_required`, written by the sweep and
  shown to students as "9 / 15 found" beside the existing student count. A
  snapshot freezes at the deadline and its bonus rides into the LEARN push, so a
  frozen row now says what coverage produced that bonus.

### Changed

- **The MCP surface derives its achievement signal list.** Four hand-typed lists
  across `initialize`, `get_achievements` and `update_achievements` are now
  rendered from `AchievementSignal.allCases` via `MCPAchievementSignalProse`,
  with `MCPAchievementSignalCoverageTests` failing on any list that stops short
  anywhere in the served catalog. Adding a seventh signal needs no MCP prose
  edit. Same fix as `MCPLanguageProse` and `MCPTierProse`, one type over.
- **An achievement condition may now compare a value AND name a reference.**
  The editor's per-signal `isTest` boolean became a closed ref kind
  (none / test / section), because a second referencing signal arrived and two
  booleans could have been true at once.
