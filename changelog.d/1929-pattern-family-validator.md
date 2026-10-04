### Changed

- **The last authoring validator throws the typed error.** `PatternFamilyValidator` built 19 `Abort(.unprocessableEntity, reason:)` values with hand-written sentences; it now throws `AuthoringValidationError`, one case per rule, with the same sentence word for word. Nothing under `Sources/APIServer/Utilities/` imports Vapor any more, so `scripts/check-utilities-imports.sh` loses its Abort-validator allowance and the fixture that proved the allowance shrank. This closes #1929.
