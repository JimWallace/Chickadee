### Added

- **UI guards for Elementary views.** `ElementaryPageGuardTests` renders every Elementary page from fixtures and applies the inline-style, script, class-resolution, CSS-variable, hover-text, heading and archetype rules to the HTML. A page without a fixture fails it. Two SwiftLint rules forbid `.style(` and `HTMLRaw(` in views, and the `ui-review` workflow now runs on `Sources/APIServer/Views/`.
- **Leaf fails loudly on two silent traps.** A page that does not export a slot its layout imports now fails to render instead of serving an empty title or body, in the server and the test app alike. `check-leaf-semantics.sh` now rejects a tag name Leaf does not know, which Leaf would otherwise render as nothing.
