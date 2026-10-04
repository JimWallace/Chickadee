### Changed

- **Manifest dependency and pattern-kind validation throw a typed error, one case per rule.** `ManifestValidation` and `PatternKindHandler` built their `Abort(.unprocessableEntity, reason:)` values with hand-written sentences, and imported Vapor for nothing else. They now throw `AuthoringValidationError`, whose description is the same sentence word for word and which leaves a route or an MCP tool as the same 422. Neither file imports Vapor now, and both leave the Utilities allowlist. This continues #1929.
