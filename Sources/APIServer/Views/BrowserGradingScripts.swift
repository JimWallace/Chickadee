// APIServer/Views/BrowserGradingScripts.swift
//
// The scripts the projector arena (`LeaderboardPresentPage`) loads before
// `browser-runner.js`, in load order. They are the grading scripts of the
// student notebook page (`NotebookBody.scripts`), which keeps its own literal
// list; tournament-arena.test.mjs fails when the two differ.

enum BrowserGradingScripts {
    /// The grading-shared modules and the executor classes `browser-runner.js`
    /// reads at load.
    static let beforeRunner = [
        "/grading-shared.js",
        "/r-grading-shared.js",
        "/lua-grading-shared.js",
        "/octave-grading-shared.js",
        "/runner-support-sources.js",
        "/grading-executors.js",
    ]
}
