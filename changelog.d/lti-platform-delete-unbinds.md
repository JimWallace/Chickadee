### Fixed

- **Deleting an LTI platform unbinds its courses.** The delete left each bound course with a dangling platform ID, so AGS grade pushes found no platform and the course could not be bound again. The platform and its course bindings now go in one transaction, and the notice says so (#1647).
