### Changed

- **Worker claim critical section shrunk to a compare-and-set (#1153).**
  Candidate collection, per-candidate assignment-requirement queries, and
  compatibility evaluation now run outside the globally-serialized
  `WorkerClaimQueue` section (previously they all held it, plus an open write
  transaction — so requirement-heavy queues multiplied the serialized section
  exactly at deadline crunch). The claim itself is an atomic
  `UPDATE … WHERE status = 'pending'`; a candidate another runner claimed
  since the scan matches zero rows and the walk moves to the next candidate.
  This also makes the claim genuinely race-safe on Postgres (single-statement
  CAS rather than read-then-write in a read-committed transaction); retiring
  the in-process queue on Postgres in favour of `FOR UPDATE SKIP LOCKED`
  remains a documented follow-up.
