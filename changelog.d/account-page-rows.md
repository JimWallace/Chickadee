### Changed

- **The account page builds its course rows outside the handler.** `enrolledCourseRow` and `availableCourseRow` in `AccountRoutes+Rows.swift` carry the slip-day arithmetic and the self-enroll gate, so the handler is loads plus render (#1715).
