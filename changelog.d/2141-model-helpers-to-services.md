### Changed

- **Four `Request`-free, model-touching web helpers moved to `Services/` (#2141).** `GradeOverrideHelpers`, `ScriptCRUDHelpers`, `CourseLookupHelpers` and `CourseRosterCounts` write or query models and never read a request, so the placement rule puts them below the routes. The layering baseline loses two lines. No behaviour change.
