### Added

- **UI guards for Elementary views.** `ElementaryPageGuardTests` renders every Elementary page from fixtures and applies the inline-style, script, class-resolution, CSS-variable, hover-text, heading and archetype rules to the HTML. A page without a fixture fails it. Two SwiftLint rules forbid `.style(` and `HTMLRaw(` in views, and the `ui-review` workflow now runs on `Sources/APIServer/Views/`.
