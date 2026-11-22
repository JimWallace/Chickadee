### Removed

- **Two overloads that only tests called.** `ScriptRunner.run(script:workDir:timeLimitSeconds:)`, the form with no `env:`, and `AvatarStore.ensureHandle(for:on:)` for an enrollment are gone. The tests now call the production forms (`env: [:]`, and the user form). Behaviour does not change (#3234).
