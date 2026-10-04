### Changed

- **The admin course page builds its rows outside the handler (#2111).** `courseDetail` built the course row, the roster rows with their avatars and the assignment rows inline. Three static builders in `AdminRoutes+CourseRows.swift` do that now, the shape the account page uses, so the handler is loads plus render. The page does not change.
