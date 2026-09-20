// Tests/CoreTests/HostConditionTraits.swift
//
// The `ConditionTrait`s CoreTests attaches to a test whose subject the host
// may legitimately lack. A trait makes the skip VISIBLE: Swift Testing
// reports it with this reason, and `scripts/check-no-skipped-tests.sh` turns
// a skip on the CI image into a red job. A `guard ... else { return }` reads
// as a pass having executed nothing, which is how three language suites once
// went green everywhere with no interpreter installed.
//
// Each test target declares its own copy of these extensions: `Testing` is
// linked into test targets only, so `ChickadeeTestSupport` cannot hold them.

import Foundation
import Testing

extension ConditionTrait {
    /// Skips, visibly, when the zip tools `Core/ZipSubprocess.swift` spawns are
    /// not at their fixed paths.
    static let requiresZipTools: ConditionTrait = .enabled(
        if: FileManager.default.fileExists(atPath: "/usr/bin/zip")
            && FileManager.default.fileExists(atPath: "/usr/bin/unzip"),
        "requires /usr/bin/zip and /usr/bin/unzip")
}

/// `@Test(.requiresZipTools)` resolves through `any TestTrait`, so the
/// implicit-member spelling needs the same `Trait where Self == ConditionTrait`
/// extension the built-in `.enabled(if:)` uses.
extension Trait where Self == ConditionTrait {
    static var requiresZipTools: Self { ConditionTrait.requiresZipTools }
}
