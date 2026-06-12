### Fixed

- **Course copy and bundle export/import now preserve course sections and
  notebooks.** Copying a course recreates its sections (names, grading modes,
  ordering) and keeps each assignment in its section instead of dumping
  everything ungrouped; the copy also follows the setup's actual stored
  notebook path, so notebooks in the `notebooks/<setupID>/` subdirectory are
  no longer silently dropped. `.chickadee` bundles carry a new optional
  `sections` array (+ `sectionBundleID` per assignment) that round-trips
  sections through export → import; older bundles without the field still
  import fine, just ungrouped. (#342)
