### Added

- **Type-in enrolment on the instructor "Enrol from CSV" page.** Alongside the
  CSV upload, instructors can now paste or type user IDs directly into a
  textarea (separated by new lines, commas, or spaces). The file and the typed
  IDs are merged and deduplicated; either input alone is enough, and submitting
  both empty surfaces an inline error. Unknown IDs are still recorded as pending
  pre-enrolments and resolved on first login, exactly as for an upload.
