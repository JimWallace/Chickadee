### Fixed

- **The 2026-08-25 mutation sweep's six survivors are answered** (#1496). Five
  were real gaps, each confirmed SURVIVED by the verifier before a test was
  written and KILLED by the new test after. Four sat in the union-class-goal
  family — `isUnionClassGoal`, `coveredItemsRequirement`, the section scoping
  of `coveredItemNames`, and `AchievementSignal.allowedScopes` — whose only
  assertions lived in `Tests/APITests`, the suite the sweep skips, so the
  Core model invariants now have Core-layer tests. The fifth pinned the C++
  object literal's empty/unrenderable split, where the swapped mutant
  rendered a plausible empty `std::map` for an unrenderable object — the
  silent wrong value the loud backstop exists to prevent. The sixth site
  needed no test: one candidate is the ledgered first-connector equivalent in
  `isSafeTopLevelStatement`, the other is already killed by
  `NotebookExtractionPredicateTests`, and `report.py` now files such a mixed
  site as answered when the survived rows number exactly the ledgered
  candidates and the killed rows account for the rest — before this rule a
  site holding a ledgered equivalent beside a killable sibling re-entered the
  open queue every week, and the queue could never reach zero.
