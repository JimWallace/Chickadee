### Changed

- **Two oversized test files are split along their seams.** `CourseBundleTests` becomes export, import validation, import records and round-trip suites that share `CourseBundleRouteFixtures`, and `AdminRoutesTests` keeps its core routes while user deletion, course management and the runners tab move to their own suites that share `AdminRouteFixtures`; every test moves unchanged.
