### Fixed

- **Twelve test helpers no longer leak a half-built app when their setup throws.** They built a bare `Application.make(.testing)` and then ran setup that can throw (a database, a route registration, a token authority, a loopback server). If that setup threw, the leaked app's `deinit` called the synchronous shutdown, which ends the whole test process with SIGILL on Linux. They now use `makeTestingApplication`, which tears the app down before it rethrows. That helper takes an `environment:` for the two mock identity providers that serve on a loopback port. (#2360)
