// pages.mjs — THE page list for the visual-regression capture AND the
// axe-core scan. One module so the two harnesses cannot drift apart (they
// carried separate copies until the UI-rendering-rules pass).
//
// Coverage is one representative per page-anatomy family (docs/ui-design.md,
// "Page archetypes") plus the pages most recently restructured:
//
//   auth            → login
//   student (bare)  → student-dashboard, student-submit, submission-pending,
//                     student-account
//   instructor tabs → instructor-assignments, instructor-students,
//                     instructor-slip-days
//   admin tabs      → admin-dashboard, admin-users, admin-alerts
//   titlebar/form   → admin-course-new
//   error page      → error-404
//
// admin-audit is deliberately NOT here: its rows are UUIDs and timestamps
// that differ every run, so a pixel baseline would be one big mask. Its
// markup is covered by the render tests.
//
// Keep names stable — they are the baseline filenames.
export function pageList({ setupID, instructorState, studentState, resultsPath }) {
  const pages = [
    { name: "login", path: "/login", state: null },
    { name: "student-dashboard", path: "/", state: studentState },
    { name: "student-submit", path: `/testsetups/${setupID}/submit`, state: studentState },
    { name: "student-account", path: "/account", state: studentState },
    { name: "error-404", path: "/this-page-does-not-exist", state: studentState },
    { name: "instructor-assignments", path: "/instructor", state: instructorState },
    { name: "instructor-students", path: "/instructor/students", state: instructorState },
    { name: "instructor-slip-days", path: "/instructor/slip-days", state: instructorState },
    { name: "admin-dashboard", path: "/admin", state: instructorState },
    { name: "admin-users", path: "/admin/users", state: instructorState },
    { name: "admin-alerts", path: "/admin/alerts", state: instructorState },
    { name: "admin-course-new", path: "/admin/courses/new", state: instructorState },
  ];
  if (resultsPath) {
    pages.push({ name: "submission-pending", path: resultsPath, state: studentState });
  }
  return pages;
}
