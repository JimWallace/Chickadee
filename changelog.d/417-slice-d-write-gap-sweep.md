### Security

- **Close the remaining per-course write gaps: assignment lifecycle, setup
  upload/notebook, submissions, drafts (#417 Slice D).** Slices A & C scoped the
  assignment-editor and per-student mutations to the resource's own course;
  this slice finishes the web sweep. The assignment lifecycle mutations
  (`open`/`close`/`status`/`delete`), drag-`reorder`, unpublished-setup delete,
  and the `:assignmentID` BrightSpace grade-push backfill now authorize via
  `requireCourseWriteAccess`, so a per-course instructor can't drive them
  cross-course or against an archived course by URL. The high-value
  `POST /api/v1/testsetups` (upload) and `PUT /api/v1/testsetups/:id/assignment`
  (notebook save) drop their global `isInstructor` check for the per-course
  gate — closing a hole where any global instructor could create a setup
  (carrying secret tests + solutions) in **any** course via a client-supplied
  `courseID`, or overwrite any course's notebook by id. Submission intake
  (`POST /api/v1/submissions[/file]`) is scoped to the setup's course via
  `requireCourseEnrollment`, and the new-assignment draft editor — the primary
  `POST /instructor/new/draft` endpoint **and** the suite/script/section
  sub-edits — authorizes the draft's own course (so a draft can't be rewritten
  cross-course by `draftID`). Also closes one adjacent cross-course **read**
  leak on the most sensitive artifact: `GET /api/v1/testsetups/:id/download`
  streamed the full setup zip (secret-tier tests + reference solution) on a bare
  global-`isInstructor` check, letting any instructor pull another course's
  secrets by id — now `requireCourseInstructor` on the setup's own course (the
  enrollment-gated student fetch is the separate `/browser-runner` route).
  Admins remain exempt; the student/browser read paths are untouched.
