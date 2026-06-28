### Security

- **Archived courses are now read-only on the server, not just in the UI
  (#417).** A new `requireCourseWriteAccess` helper blocks non-admin writes to
  an archived course, and the assignment-editor mutations
  (`saveEditedAssignment`, `PUT /suite`, script/section/global-variable/
  achievement edits, `create-solution`) plus the per-course enrollment
  mutations now authorize against the **resource's own course** instead of
  trusting only the active-course group middleware. This closes a gap where a
  per-course instructor could edit (or mutate enrollment on) an *archived* —
  or a different — course's content by URL. Admins remain exempt (they own
  unarchiving); read access to archived courses is unchanged for grade audits.
