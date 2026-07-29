### Fixed

- **Browser-graded assignments now auto-push grades to LEARN.** Only the worker
  result path flagged a result for BrightSpace grade sync, so a notebook
  (browser-graded) assignment never queued a push at all — the 60-second sweep
  only ever sees rows flagged at ingest. Grades for those assignments reached
  LEARN only when an instructor pressed "Push all" by hand, or when a retest
  happened to route the submission through a worker. The flagging gate is now a
  shared helper (`flagResultForBrightSpaceSync`) called by both ingest paths.

- **A student missing from the LEARN classlist no longer produces an unusable
  grade push.** When the classlist lookup missed, resolution fell through to the
  LMS-global `users/?orgDefinedId=` lookup, which returns the account of a
  student who is not enrolled in the course. D2L rejected the resulting push
  with a bare `HTTP 404: Not Found`, and the unusable D2L user id was cached on
  the user row — so every later push for that student, on every assignment,
  failed identically forever. A *populated* classlist is now authoritative: a
  student absent from it is recorded as a skip naming their org unit, instead of
  a 404. An empty or unreadable classlist is still not treated as authoritative,
  so a Valence permission gap or transient outage cannot strand every push.

- **A 404 grade push now invalidates the cached D2L user id.** The grade item is
  fetched successfully immediately before the push, so a 404 from the values
  endpoint is about the user, not the item. The cached id is dropped so the next
  attempt re-resolves against the classlist rather than replaying the same
  failure. Other statuses leave the cached id intact.
