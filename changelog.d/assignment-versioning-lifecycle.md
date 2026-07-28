### Added

- **Assignment versioning — lifecycle (slice 5).** Cloning an assignment,
  copying a course, or creating one from scratch now seeds the new setup's
  own version 1, so a fresh copy has a starting point to roll back to and
  records where it came from. Cloning still carries only current content —
  the copy lands in a new setup, so none of the source's history travels with
  it. Deleting a course reclaims the blobs its version rows referenced, and
  reclamation is deliberately conservative: it skips entirely if it cannot
  read the full reference set, and ignores blobs written in the last hour so
  it can never race a snapshot that has stored its bytes but not yet committed
  its row.

### Fixed

- **Empty test-setup zips could not be snapshotted.** `unzip` exits non-zero
  on a valid but empty archive, so version capture treated the empty setup a
  from-scratch assignment starts with (or one whose last script was deleted)
  as an unreadable zip and silently recorded no version. Genuinely corrupt
  archives still fail loudly rather than being recorded as an empty suite.
