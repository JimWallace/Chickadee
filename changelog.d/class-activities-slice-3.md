### Added

- **Class activities, slice 3: king of the hill (#1508).** A new activity
  kind, `kingOfTheHill` ("Beat the champion"), plays each submission against
  whoever holds the hill: the bundled bot in `opponentFile` until a student
  does, then that student's submission, which the native worker downloads and
  stages in `CHICKADEE_OPPONENT_DIR` the way the challenger's own upload is
  staged, with `.chickadee_student_module` naming the opponent's module. A
  match the script passes (exit 0) takes the hill; a loss to the champion
  counts a defence. `match_results` rows are opened when a job is claimed and
  completed when its result lands, so the hill moves on what the job actually
  played, never on the champion of the moment, and a replayed report or a
  re-test of the champion changes nothing. `activity_champions` holds the one
  holder per assignment; the leaderboard names them by handle with "since" and
  the streak; `RecordDimension.champion` is a held record `set_activity` seeds
  beside the leaderboard record. The kind is worker-only by construction, and
  its jobs wait for a runner advertising the new `activity-opponent-submission`
  build capability. The design note is `docs/class-activities.md`.
