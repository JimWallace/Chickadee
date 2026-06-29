### Added

- **LEARN roster sync readiness.** Chickadee now proactively tracks, per
  student per course, whether it can deliver that student's grade to the LEARN
  gradebook. A background sweep (every 10 minutes, built on the shared
  `PeriodicSweepMonitor`) reconciles each BrightSpace-linked course's roster
  against its LEARN classlist and persists a status on the enrollment —
  **confirmed** (matched, we can push), **unconfirmed** (not yet checked), or
  **unreachable** (not on the classlist, or no identity to match on, with the
  reason). The instructor LEARN tab gains a **roster-readiness panel** with the
  confirmed/unconfirmed/unreachable counts, the last-checked time, the list of
  unreachable students, and a **Reconcile now** button for an on-demand
  re-check. This is a signal layer only — an unreachable student's grade still
  queues and is never lost; the panel just surfaces that we can't deliver it
  yet, before term-end. It reuses the existing `LearnRosterReconciler`
  classification and replaces the LEARN tab's old log-heuristic "unmapped
  students" section.
