### Fixed

- **A solution notebook's broken demo cell no longer silently breaks
  `solution.py` for personalization.** The server-side `solution.py` that
  per-student expressions import (`solution.<fn>(...)`) was a naive
  concatenation of the solution notebook's code cells, so a single cell that
  errored at import — e.g. a copy-pasted JSON-ism like a bare `null` in a
  module-level list literal, or a failing example-test `assert` — aborted
  `import solution` for the whole module. The personalization evaluator's import
  guard then swallowed it, and every `solution.<fn>` reference surfaced as a
  baffling `name 'solution' is not defined`. `SolutionNotebookExtractor` now
  renders `solution.py` through the shared `RunnerCore.extractPython` — the same
  resilient extractor the native worker and browser runner use to grade — so
  each cell loads under its own `try/except`, side-effecting statements are
  quarantined into `if __name__ == "__main__":`, and a broken demo cell is
  skipped without taking the helper functions down with it. Using one extractor
  for both paths also means the imported solution and the graded solution can't
  diverge.
