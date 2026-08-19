### Fixed

- **The mutation sweep derives its shard count from one place.** The number
  lived in three — `Tools/mutation/config.json`, the workflow's hardcoded
  `shard: [0, 1, 2]` matrix, and whatever `--of` a dispatch passed — hand-synced,
  with a silent failure mode: dispatching `shards: 5` left the matrix at three
  jobs, so two shards' files were never mutated while the aggregator, reading
  the config, saw 3 of 3 and called it a complete sweep. A `plan` job now emits
  the matrix and the denominator from a single read.
