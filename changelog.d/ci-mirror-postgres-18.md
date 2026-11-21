### Changed

- **CI mirrors `postgres:18` into GHCR.** First step of the Postgres 16 → 18 upgrade (#3148): the image must be in GHCR before the test jobs can point at it.
