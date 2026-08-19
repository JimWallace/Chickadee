### Changed

- **The weekly mutation sweep now covers `Sources/Core` as well as
  `Sources/RunnerCore`** — ~10,200 LOC and ~1,700 mutants across 8 shards, up
  from ~1,600 and ~266 across 3. Widened on the condition the previous config
  named: a green run at the narrower scope, which run 3 delivered at 84%.
  Shard count is set by measured cost — ~29 min fixed per shard plus ~9.8s per
  mutant — so the estimate in `--plan` now reflects both terms instead of a
  per-mutant figure that omitted setup entirely. Core survivors carry a caveat
  RunnerCore's do not: 5% of Core is reachable only from the skipped `APITests`,
  and a survivor there may be an artefact rather than a hole.

### Fixed

- **A second mutation sweep on the same day silently overwrote the first.** The
  run record was keyed by date alone, so a manual dispatch beside the Tuesday
  schedule — the normal way the sweep gets run on demand — replaced that week's
  record rather than adding to it. Records now carry the run id, and `trend.py`
  orders same-day runs deterministically.
