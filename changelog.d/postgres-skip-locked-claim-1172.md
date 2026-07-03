### Changed

- **Postgres job claims use `FOR UPDATE SKIP LOCKED` (#1172).** Since the
  claim became an atomic compare-and-set (#1153), the in-process
  `WorkerClaimQueue` only existed to keep concurrent polls from thrashing
  SQLite's write lock — on Postgres that serialization was pure overhead.
  The Postgres claim now runs in a short transaction that row-locks the
  already-evaluated candidate with `SELECT … FOR UPDATE SKIP LOCKED` before
  stamping it, so concurrent claims from any number of runners and server
  processes proceed in parallel; a contended row is skipped instantly
  instead of queued behind the winner. Candidate ordering (fresh student
  work before retests, validation last) and the requirement-compatibility
  walk are unchanged, and the SQLite path (actor + compare-and-set) is
  untouched.
