### Changed

- **Achievements unification (A2): per-submission badges are manifest-driven.**
  `forSubmission` now sources the per-submission badges (Ace / Rally / Tenacious
  / Swift) from the assignment manifest's authored achievements when present,
  falling back to the built-in registry otherwise — wired at all three display
  sites (submission page, course history, student dashboard). Behavior-identical
  until a manifest carries per-submission achievements (the editor + seeding land
  later in the rollout); the parameterized thresholds then take effect.
