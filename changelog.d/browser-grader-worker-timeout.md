### Fixed

- **Browser grader survives CPU-bound infinite loops in student code.** The
  in-browser submission grader now runs student Python in a Web Worker
  (`Public/grading-worker.js`) instead of on the main thread, so a synchronous
  run-away loop (e.g. `while True: pass`) that never yields to JS can be killed
  via `Worker.terminate()` when the per-test time limit fires — previously the
  `Promise.race` sleep timer never got a turn, the tab froze, and the submission
  was lost. After a timeout a fresh worker is respawned to grade the remaining
  tests. Environments without `Worker` keep the unchanged main-thread path.
