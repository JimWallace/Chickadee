### Fixed

- **Unenrolled admins no longer see course content they're not part of.** An
  admin (or any user) with no course enrollment was shown the course-scoped
  "Instructor" nav tab and a deployment-wide list of every assignment/test
  setup on the home dashboard. The home dashboard is now course-scoped for
  every role — with no active enrollment it renders the empty "not enrolled in
  any courses" state, and the Instructor tab only appears for a user enrolled
  in a course (labelled with the active course code). The global admin role
  still grants the Admin tab and `/admin`; course participation is governed by
  enrollment, matching the existing `CourseAccessHelpers` policy.
