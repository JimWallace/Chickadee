### Fixed

- **The assignments dashboard no longer shows a TA the instructor-only controls.** A TA does not see "+ Add Section", the section edit and delete controls, the status select, "Publish…", "Duplicate", "Delete assignment" or "Delete setup". The server refuses each of these actions for a TA. A TA sees the status as a read-only label and keeps retest, edit and the material items. The route handlers and the page read the same floors (`DashboardRoleFloor`), so they cannot drift. A TA also cannot open the enrol-CSV form by URL (#2743).
