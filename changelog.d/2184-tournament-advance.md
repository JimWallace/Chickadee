### Fixed

- **A tournament round advances once, and a failed advance can finish.** Two match results landing together could both advance from a stale copy of the run, so the second could complete the run with no winner. An error in the advance stalled the run for ever, because a replayed report returned early. The advance now reads the run fresh in one transaction and claims each step with one conditional update, a replayed report retries it, the ingest calls it best effort, and starting a tournament is one transaction.
