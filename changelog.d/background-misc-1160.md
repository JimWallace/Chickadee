### Changed

- **Background query cleanups from the 2026-07 audit (#1160).** The
  class-goal achievement sweep resolves the enrolled-student denominator
  with one course-scoped query pair per tick instead of a roster query per
  assignment, and reads grades through the blob-free summary loader; the
  job-claim path fingerprints an edited setup zip by streaming it in 1 MiB
  chunks on the thread pool instead of reading the whole archive into heap
  (digest unchanged, so runner download caches carry over); and the
  deployment-wide enrollment fetches behind the grades CSV student list and
  the roster-counts map are now filtered database-side / scopeable by
  course.
