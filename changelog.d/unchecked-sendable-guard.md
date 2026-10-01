### Changed

- **The `@unchecked Sendable` comment rule is enforced, with Fluent models exempt.** `scripts/check-unchecked-sendable.sh` fails `format-lint` on any non-model declaration that has no comment saying why the conformance is unchecked. Fluent `Model` classes are exempt, because the reason is always the same, and the convention in CLAUDE.md now says so (#1658).
