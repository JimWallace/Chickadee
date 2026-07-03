### Changed

- **Grade queries stopped dragging the results blob, and result size is now
  bounded (#1157).** The grades CSV export, instructor roster, per-student
  drilldowns, and BrightSpace grade sync previously loaded full result rows —
  `collection_json` included — just to read four denormalized grade columns
  (hundreds of MB of heap for one large-course CSV export). A blob-free
  projected loader now feeds every grade fold, with a legacy fallback for
  pre-backfill rows so the two paths can never disagree. Separately, a
  serialized-size budget (6 MB) now applies to every result collection at
  report time: the worker truncates verbose `longResult`s/`compilerOutput`
  across the collection before posting (statuses, short results, and grades
  untouched; a visible warning is appended), the server applies the same
  guard against older runners, and the result-ingest body limit rose to
  32 MB — an oversized report is truncated loudly instead of rejected with
  the submission stuck unresolved.
