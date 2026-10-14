### Changed

- **More preparation for Vapor 5.** Configuration now reads the environment through a Swift Configuration `ConfigReader`, the type Vapor 5 reads its settings through. Every variable keeps its name, and no variable is added. The CSRF token read collects the body through a `collectBody` helper and reads `_csrf` through `decodeContent`, so it no longer uses `content.get(_:at:)` or waits on a future. `scripts/check-vapor5-readiness.sh` now also blocks `content.get` and waits on a future. Behaviour does not change. See `docs/vapor-5-migration.md`.
