### Fixed

- **BrightSpace grade sync scales to the grade item's own max.** Chickadee
  previously pushed raw suite points and assumed the LEARN grade item's Max
  Points equaled the assignment's suite total — so an assignment graded out of
  more points than its grade item (with "Can Exceed" off) was rejected by D2L
  with an opaque empty-body `400`. The sweep now fetches the grade item's max
  at push time and pushes `percentage × maxPoints`, so a 100% always lands as
  full marks regardless of how the two totals compare. When the item's max is
  unknown or already matches, the pushed value is unchanged.

### Added

- **Grade-item type is surfaced and enforced in BrightSpace sync.** The
  instructor grade-item dropdown now shows each item's D2L type and flags
  non-Numeric items as unsupported, and the sync refuses to push points to a
  non-Numeric item with a clear message instead of a bare D2L `400`. Grade-push
  failures now record the item's name, max points, and the attempted value in
  the sync-activity log so a rejected push is self-explanatory.
