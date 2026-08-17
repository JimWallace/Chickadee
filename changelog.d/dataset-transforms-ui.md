### Added

- **The Files panel can now author a `missingValues` step.** A dataset row grows
  a "blanking … in … % of rows" control beside its sample size and stratum
  column. As with the stratum column, the field carries whether the step exists
  — naming columns creates it, clearing them removes it — so there is no mode
  picker whose state could contradict the fields. Rates are authored as a
  percentage and stored as the fraction the materializer folds to an integer
  count.

  The panel edits exactly one shape: no transforms, or a single `missingValues`
  step. A spec holding anything richer — two steps, or a kind a later release
  adds — renders with the fields **disabled** and a note that the steps are
  agent-authored, and an unrelated edit to that row carries them through
  untouched. Showing half of a two-step spec is how the next row-count edit
  would save over the half not shown.
