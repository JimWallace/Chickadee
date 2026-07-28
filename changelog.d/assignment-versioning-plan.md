### Added

- **Assignment versioning and recovery — storage core (slice 1).** Content edits
  can now be snapshotted: a new `assignment_versions` table records an
  assignment's manifest, setup-zip contents, and starter notebook as an
  immutable, append-only history, with bytes held in a content-addressed
  per-file blob store so unchanged datasets and notebooks are stored once
  regardless of how many versions reference them. `AssignmentVersionStore`
  is self-deduping (an edit that changed nothing writes no row) and seeds a
  lazy pre-edit baseline so the first edit on an existing assignment stays
  recoverable. No capture points are wired yet and no behaviour changes;
  design in `docs/assignment-versioning.md`.
