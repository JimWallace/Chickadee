### Changed

- **A class-goal bonus is now true extra credit, uncapped.** It used to be capped
  at 100% of the suite total, which made the reward invisible to exactly the
  students who earned it: a goal conditioned on "N% of the class reaches 100%"
  leaves most of the class at full marks, where the cap absorbed the whole bonus.
  (HLTH 230 Lab 9: a +1 bonus worth 25% of a 4-point suite showed up as no change
  at all for the majority.) A student at full marks now reads above 100% on the
  submission page, in the grades CSV, and in LEARN. The grades CSV had grown its
  own copy of the cap inline; all three grade-of-record sites now call the single
  shared helper.

### Fixed

- **A class-goal bonus now reaches LEARN at all.** The bonus scales with live
  class progress, but a BrightSpace push is only ever queued by an event on a row
  — a new result, an instructor override, or the manual "Push all" — and class
  progress moving queued nothing. So each student's LEARN grade froze at whatever
  share of the class had reached the goal *at the moment their own submission was
  graded*, leaving the earliest submitters under-credited permanently, while
  Chickadee's own pages (which compute the bonus live) showed the full amount.
  The class-goal sweep now re-queues every student's grade for one push when a
  points-rewarded goal **freezes at the deadline** — the moment the final bonus
  exists. It fires once per assignment, is gated on the assignment being bound to
  a LEARN grade item and not excluded from sync, and leaves the live window alone
  (a goal still moving would otherwise re-push the whole class every sweep). An
  assignment with no due date never freezes, so "Push all" remains the way to
  settle its bonus.

- **A grade push above a LEARN item's maximum is now reported.** D2L's
  `CanExceed` flag was decoded onto `BrightSpaceGradeObject` but never consulted.
  Uncapped extra credit makes an above-max push reachable by design, and it is
  the one way the bonus can be computed correctly and still not appear in LEARN,
  since D2L may clamp or reject the value. The push still goes out — a clamped
  grade beats no grade — and the sync-activity log's success row now names the
  item, its maximum, and the fix (tick "Can Exceed" on the grade item).
