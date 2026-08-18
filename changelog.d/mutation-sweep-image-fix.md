### Fixed

- **The weekly mutation sweep now names the image that has the interpreters.**
  Run 1 died on all ten shards in under a second: the workflow asked for
  `swift:6.3-noble`, the toolchain-only image, where the runner's own
  `python3 not on PATH` guard fires immediately. It now uses `swift-ci:6.3-noble`
  like `api-tests` and `worker-tests`.
- **A sweep where every shard dies no longer reports success.** The aggregator
  counted only the artifacts it found, so ten failed shards produced an empty
  list, zero survivors, and a green job that filed nothing — the exact "partial
  coverage reads as clean" failure the sweep is built to prevent, in its most
  complete form. It now compares against the expected shard count from
  `Tools/mutation/config.json`, fails the job when nothing reported at all, and
  counts shards that actually produced a report rather than shards that uploaded
  a directory.
