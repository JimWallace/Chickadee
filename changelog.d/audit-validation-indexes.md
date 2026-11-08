### Fixed

- **Indexes for three full-table scans.** `validation_variants` gains indexes on `(test_setup_id, variant_index)` and `submission_id`, `audit_log` on `actor_user_id` and `target_id`, and `class_achievements` on `submission_id`. The instructor landing page, every validation result, the data export, user deletion (a `SET NULL` cascade on `audit_log`) and the submission page each scanned one of these tables.
