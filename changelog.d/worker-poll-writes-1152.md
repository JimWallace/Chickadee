### Changed

- **Idle worker polls no longer write to the database (#1152).** Every
  `POST /worker/request` previously cost a `RunnerProfile` UPDATE, a
  `RunnerSnapshot` INSERT, and a globally-serialized claim transaction with
  2–3 SELECTs — at up to one poll per second per runner, even with an empty
  queue. The profile's `lastSeenAt` now persists at most once per 60 s when
  nothing else changed (capability changes, display-name changes, and
  reactivation still write immediately); runner snapshots are sampled — one
  row per runner per 30 s, with an immediate row on any activeJobs/maxJobs
  change so load spikes keep full resolution; and an indexed existence probe
  short-circuits the claim path before the serialized transaction when no
  pending submission exists.
