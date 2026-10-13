### Fixed

- **Deleting a course removes its class-coverage rows.** `deleteCourse` deleted `class_coverage_runs` but not `class_item_coverage`, which has no foreign key, so a deleted course left behind the record of which student covered each item.
