### Tests

- **One repository root for tests.** `ChickadeeTestSupport` now has `repositoryRoot`. About sixty sites that counted `deletingLastPathComponent` from their own file use it, and four sites that read the working directory now do not depend on it. (#2367)
