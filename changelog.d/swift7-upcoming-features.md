### Changed

- **Three more Swift 7 features.** Every target now builds with `InternalImportsByDefault`, `InferIsolatedConformances` and `ImmutableWeakCaptures`. An import is internal unless the file writes `public import`, so the compiler shows each module that appears in a public API: Foundation in 21 `Core` files, and swift-subprocess in `BoundedSubprocess.swift`. The other two features needed no change. `NonisolatedNonsendingByDefault` waits for the Vapor 5 move (#1523).
