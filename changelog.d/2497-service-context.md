### Changed

- **Service functions no longer take a whole request.** The validation service, the content-edit effects and the audit logger take a `ServiceContext` or an `AuditContext`, which carry only the database, the logger, the application and the acting user. A request conforms, so the routes pass it as before, and a caller with no request can now call them (#2497).
