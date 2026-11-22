### Changed

- **Tests for uncovered instructor and admin routes.** New tests cover `GET` and `PUT /instructor/:assignmentID/global-variables` (a save by a TA, a refused save, a student), `GET /instructor/metrics/cards` (only the active course counts; no active course gives no windows), `PUT /instructor/new/draft/suite` and `DELETE /instructor/new/draft/scripts/:filename`, and the banner that each Deployment page notice shows. No product code changed.
