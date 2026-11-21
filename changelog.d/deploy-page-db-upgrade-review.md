### Changed

- **The admin Deployment page alerts on a failed database upgrade.** A failed or
  rolled-back PostgreSQL upgrade shows an error banner on the held card, or above
  the running card when nothing is held. The upgrade warning is one sentence and
  still shows while the release notes are missing or stale, the approve note says
  the approval upgrades the database first, and a long value on the running card
  (a log path) wraps at phone width.
