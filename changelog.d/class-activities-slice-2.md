### Added

- **Class activities, slice 2: the opponent primitive (#1508).** A
  `beatTheInstructor` assignment now names the bot it plays: `opponentFile` on
  the `activity` block, chosen in the edit page's Activity section or with
  `set_activity`, from the assignment's support files. The native worker stages
  that file in a directory the match script reads from `CHICKADEE_OPPONENT_DIR`
  and hands it a per-match seed in `CHICKADEE_MATCH_SEED`, derived from the
  submission and the opponent so a re-test replays the same trials. The
  opponent axis is a type (`ActivityOpponentSource`: `none` | `supportFile`),
  read off the kind exhaustively; the runner learns a match's needs from the
  structural `Job.opponent`, never from the activity enum, and every runner
  build that can stage an opponent advertises `activity-match`, which
  `RunnerActivityGate` requires at claim so an older build cannot grade a bot
  match with no bot. Browser grading is refused for any activity that stages an
  opponent, at every door that refuses grader-only files. An opponent is staged
  only once a file is chosen, so a slice-1 activity with a hand-wired bot grades
  exactly as before; a chosen bot missing from the setup fails the job loudly
  with the fix named, on the instructor's validation run. `get_assignment`, `set_activity` and `get_server_info` report
  the opponent source and file. The design note is `docs/class-activities.md`.

### Fixed

- **The web session hook installs the toolchain the package needs.**
  `.claude/hooks/session-start.sh` still pinned Swift 6.3 after the 6.4 move,
  so every Claude Code on the web session failed at `swift build` with a
  tools-version error. It pins 6.4.0 now — the full patch version, because
  swift.org publishes 6.4 under `swift-6.4.0-release/` and a two-part pin 404s.
