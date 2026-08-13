### Fixed

- **Queue bookkeeping no longer gets slower as the backlog deepens.** The
  `queue_depth` diagnostic loaded every pending student submission into memory
  on every job claim and every accepted submission, then issued one test-setup
  lookup and manifest decode per distinct assignment — so a deep queue, or a
  retest fan-out flipping tens of thousands of rows back to pending, made each
  claim and each intake progressively more expensive. It is now two SQL
  aggregates plus one batched grading-mode lookup, costing what the number of
  distinct pending assignments costs rather than what the queue depth costs.
  The reported number is unchanged.
- **Indexed the worker claim query's fresh-work-first split.** Claims ask for
  pending student work with `retested_at IS NULL` before falling back to
  retests (#427), but the existing submissions index stopped at `submitted_at`.
  A retest-dominated queue — precisely the case that split exists to handle —
  made every poll walk the whole pending range. Added
  `idx_submissions_claim_priority` covering `(status, kind, retested_at,
  submitted_at)`.
