### Changed

- **Dataset formats state what they allow.** Each dataset format now lists
  the settings a spec of it accepts: a sample, a stratum, a partition and
  transforms. The materializer, the save-time checks, the Files panel and its
  script read that list instead of asking whether a file is a CSV. A spec with
  a format this server does not know still loads, keeps its value and delivers
  the file whole, and an edit of it is refused. A course bundle that carries
  such a format is refused by name. This lets a later format ship without
  breaking a blue-green switchover or a rollback
  (docs/dataset-kinds-plan.md).
