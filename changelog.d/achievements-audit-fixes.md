### Fixed

- **Achievement `testPass` refs now match real runner outcomes.** Refs are
  authored as script filenames, but runners stamp `testName` as the display
  name (else the filename stem), so a per-contract badge could never fire.
  Matching now resolves filenames, stems, and display names via a
  manifest-derived alias map, refs are validated against the suite on save
  (unknown refs and duplicate achievement ids are rejected), and badges
  mixing a dynamic signal (attempts/time/jump) with `testPass` are now
  satisfiable on the submission page.
- **Browser-graded assignments now award class records.** Pathfinder
  (first-to-submit) and the 100% records (Trailblazer / fastest /
  fewest-attempts) were only awarded on the zip-upload and worker-report
  paths; the notebook `browser-result`, `runner-submit`, and
  `browser-failover` routes now award them too.
- **Web suite-editor script add/delete no longer wipes achievements.** The
  two manifest-rebuild helpers dropped `achievements`,
  `disabledBuiltInAwardIDs`, and `builtInAchievementsSeeded`, silently
  resetting a curated list to the built-in defaults.
- **Clearing built-in achievements now sticks at award time.** A curated
  (seeded) manifest with no per-submission badges or records suppressed the
  registry fallback in the editor's GET view only; evaluation now honors it
  too.
- **Class goals are validated to the shapes the sweep evaluates.** ClassWide
  achievements accept at most one `grade ≥ X` condition (richer shapes were
  saved and then silently mis-evaluated as grade-only, mis-computing bonus
  points); the sweep skips-and-logs unevaluable goals from hand-authored
  manifests instead of mis-grading them.
- **Class-goal numerator counts only enrolled students.** Staff test
  submissions and dropped students no longer inflate `studentsMeeting`
  (the denominator already excluded them), which could grant unearned bonus
  points to the grades CSV and BrightSpace.
- **Manifest-authored class records now display.** Custom-ID records (and
  renamed built-ins) were awarded in the database but invisible — display
  resolution now checks the manifest before the registry on the submission
  page, dashboard, and per-student history.
- **Achievements editor no longer risks wiping the list after a failed
  load.** A failed initial GET rendered an empty table whose next save PUT
  that emptiness wholesale; editing is now disabled with an error banner
  until the list loads. Also fixed "+1 pts" pluralization.
- **`shortest` record dimension documented correctly.** It ranks by fewest
  attempts to reach 100% (matching the built-in Minimalist's copy), not
  solution length; the Core doc comment and MCP schema now say so.
