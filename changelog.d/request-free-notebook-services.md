### Changed

- **The notebook working-copy store and the new-assignment draft service no longer take a `Request`.** They take a database, the application and a logger, as the BrightSpace services do. The closed-assignment gate now returns a `ClosedAssignmentGate` value, and the route makes the redirect. The two assignment gates that read the per-request role cache moved from `AssignmentDeadlineService` into `Routes/StudentAssignmentRequestGates.swift`. No behaviour changes (#1732).
