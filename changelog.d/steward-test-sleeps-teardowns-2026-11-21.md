### Changed

- **Shorter subprocess deadline test and plain test teardowns.** `BoundedSubprocessTests` waits 2.5 s instead of 3.5 s for its teardown check. The pattern-family fixture and the seed-pool tests tear their apps down through `withApp`; the two-app helper says why it cannot.
