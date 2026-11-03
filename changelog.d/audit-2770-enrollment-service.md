### Fixed

- **The instructor staff invite follows the placeholder rule.** Under local sign-in only, the instructor roster's "Add staff member" form made a placeholder account that no login could adopt. It now refuses an unknown username, as the admin forms do. The admin and instructor unenroll, set-role and staff-invite handlers share one `CourseEnrollmentService` (#2770).
