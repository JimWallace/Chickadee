### Fixed

- **LEARN grade push now includes the mandatory comment fields.** D2L's
  `IncomingGradeValueNumeric` requires `Comments` and `PrivateComments`
  RichText blocks; omitting them rejected every push with HTTP 400 "Comments
  and PrivateComments are mandatory". `BrightSpaceAPIClient.pushGrade` now
  sends empty `Text` RichText for both, so grades actually write to LEARN.
- **LEARN unmapped-students panel no longer misflags username matches.** The
  instructor sync panel decided a student was unmapped purely on an empty
  student/org-defined ID, which wrongly listed students who match LEARN by
  username (and whose resolved D2L id is already cached). It now treats a
  student as unmapped only when they have neither a student number nor an
  already-resolved LEARN id.
