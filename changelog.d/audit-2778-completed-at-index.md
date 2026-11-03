### Fixed

- **Index the job metrics and course child tables.** A new migration adds an index on `job_execution_metrics(completed_at)`, which the health rule, the diagnostics cards and the nightly prune filter on. It also indexes `course_id` on `course_sections` and `course_content_items`, which every course page filters on. Before, each of these queries scanned the table (#2778).
