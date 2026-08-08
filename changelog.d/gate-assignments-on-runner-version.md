### Changed

- **Documented the rule that an assignment needing a runner-side feature must
  be gated on `minimumRunnerVersion` at authoring time.** Runners upgrade
  independently of the auto-deployed server, so claim order decides which build
  grades a job: an ungated assignment validates green whenever a capable runner
  polls first, then fails for the next student whose job an older runner claims
  — with a symptom (exit 127, "interpreter not found") that reads as a broken
  test script. `docs/runner-capability-profiles.md` gains an authoring rule with
  the landing versions (Lua 0.5.23, Octave 0.5.24, C++ 0.5.27), a note that
  browser-graded assignments are not exempt because validation always runs on the
  native worker, and why capability requirements are not a substitute — they fail
  the opposite way, matching no runner and queueing jobs forever. Cross-linked
  from `CLAUDE.md` and the new-language checklist in
  `docs/adding-a-xeus-kernel.md`.
