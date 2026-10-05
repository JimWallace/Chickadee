### Fixed

- **The personal-data export names each course offering.** Enrollments and submissions carried only the course code, so a student who took a course twice could not tell the two offerings apart. Both now carry `courseKey` (for example `CS135-F26`) and `courseTerm` (for example `Fall 2026`), and enrollments list the newest term first (#2230).
