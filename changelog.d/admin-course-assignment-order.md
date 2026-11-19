### Fixed

- **The admin course page lists assignments that share a due date in a fixed order.** The list sorted only by due date, so the order of a tie depended on which index the database planner chose. When `DropCoveredIndexes` removed `idx_assignments_course_id`, the tie flipped and the `admin-course` visual baseline failed on `main`. Ties now go oldest first (creation time, then id).
