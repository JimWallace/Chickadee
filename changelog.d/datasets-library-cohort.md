### Added

- **Course dataset library, slice 4: the course cohort.** A library dataset attached with course scope now gives a student the same rows in every assignment of the course. A per-(student, course) seed is issued the first time such a dataset is delivered, and the worker job, the browser seed endpoint, the editor copy, the notebook substitution, validation variants, composite spares and the MCP personalization preview all use it. A source scan fails the build if a server call resolves dataset slices without it.

### Fixed

- **A student's editor copy of a dataset follows a stratum or transform edit.** The editor's materialization cache keyed only on the sample kind and size, so those edits left the old rows in place until something else changed.
