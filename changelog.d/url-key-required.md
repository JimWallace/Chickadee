### Changed

- **`CourseContext.urlKey` is required.** It was optional, nil only in a context built without a course model, and `pathKey` fell back to the bare code; both constructors always passed it, so the fallback existed only for a future context that would silently write bare-code links for a termed course. The field is non-optional, the fallback is gone, and the three vanity-link writers read `urlKey` directly (#1787).
