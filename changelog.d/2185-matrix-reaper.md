### Fixed

- **The stuck-job reaper waits for a long matrix job.** A round-robin or tests-and-code job runs the suite once per classmate, but the reaper put every job back to pending after ten minutes. In a large class a second runner then played every match again. A job that plays opponents now gets one suite budget more per opponent.
