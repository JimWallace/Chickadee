### Fixed

- **Runtime-state notebook checks now see the notebook as executed.** The
  notebook extractor's import quarantine (#371) moves side-effecting top-level
  statements — including any assignment whose right side calls a function, like
  `df = pd.read_csv(...)`, and every plotting call — into an
  `if __name__ == "__main__":` block that never runs when the check harness
  *imports* the student module. The runtime-state checks (`variable_exists`,
  `data_frame_shape`/`columns`/`equality`, `series_equality`,
  `numeric_array_close`, `figure_count`) therefore could never pass on a real
  data-analysis notebook — the instructor's own reference solution failed
  validation (the HLTH 230 Assignment 4 failure). `test_runtime` gains
  `student_main_state()`, which executes the student module once with
  `run_name="__main__"` (the per-cell try/except wrappers still isolate broken
  cells) and caches the resulting namespace; the runtime-state check renderers
  now read that as-executed state instead of the import-mode module. Imports
  stay quarantined everywhere else, so pattern-family function grading is
  unchanged. All three `test_runtime.py` copies (worker embed, browser embed,
  canonical) stay in sync under the existing drift guards.

### Added

- **`set_dataset` MCP tool — the first authoring surface for per-student
  datasets.** The Phase 1 datasets backend (docs/datasets.md: deterministic
  per-seed row samples delivered under the same filename to the editor, the
  worker, and browser grading) shipped with a `PUT /instructor/:id/datasets`
  endpoint but no caller — neither the web editor nor MCP could set a spec.
  Agents can now mark a bundled support file as a per-student dataset
  (`set_dataset` with a `sampleSize`, `remove:true` to clear), and
  `get_support_files` reports the mark (`isDataset` / `datasetSampleSize`).
  Mirrors the web endpoint's validation and, like it, neither closes the
  assignment nor triggers a regrade.
