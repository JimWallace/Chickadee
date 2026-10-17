### Changed

- **APITests is grouped by feature.** The 475 suites that sat in one flat directory now live in 17 feature folders, such as `Assignments`, `Grading` and `Guards`. The top level holds only the shared helpers, and `APITestsLayoutTests` fails on a suite placed there. No test changed except for its path.
