### Changed

- **Counts move into the database.** `get_request_metrics` groups the window's requests by method, path, status and duration in SQL, and `query_audit_log` groups by action, instead of loading every row of a window of up to 30 and 90 days. The enrolled-student counts filter staff out in SQL and read only the course column, so the admin dashboard no longer loads both roster tables in full. Every count and percentile is unchanged.
