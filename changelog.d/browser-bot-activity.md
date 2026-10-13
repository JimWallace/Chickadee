### Added

- **Browser-graded bot challenges.** A `beatTheInstructor` activity, and a bracket entrant's practice run, can now be browser-graded. The browser runner stages the instructor's bot in `CHICKADEE_OPPONENT_DIR` and sets a fresh `CHICKADEE_MATCH_SEED`, as the native worker does, so a lecture activity puts no load on the runners. The bot's source reaches the browser, so it cannot be grader-only. King of the hill and round robin still need worker grading.
