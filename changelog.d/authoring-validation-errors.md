### Changed

- **Manifest dependency validation throws a typed error, one case per rule.** `ManifestValidation` built its `Abort(.unprocessableEntity, reason:)` values with hand-written sentences, and imported Vapor for nothing else. It now throws `AuthoringValidationError`, whose description is the same sentence word for word and which leaves a route or an MCP tool as the same 422. The file no longer imports Vapor and leaves the Utilities allowlist. This continues #1929.
