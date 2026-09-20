// Tests/APITests/HostConditionTraits.swift
//
// The `ConditionTrait`s APITests attaches to a test whose subject the host
// may legitimately lack. A trait makes the skip VISIBLE: Swift Testing
// reports it with this reason, in the log and in the xUnit report, and
// `scripts/check-no-skipped-tests.sh` turns a skip on the CI image into a red
// job. A `guard ... else { return }` reads as a pass having executed nothing,
// which is how the R suites once went green for a whole release series with
// no Rscript installed.
//
// Each test target declares its own copy of these extensions: `Testing` is
// linked into test targets only, so `ChickadeeTestSupport` cannot hold them.
// The probes behind them (`cachedToolIsAvailable`) are shared.

import ChickadeeTestSupport
import Foundation
import Testing

extension ConditionTrait {
    /// Runs the test only in CI, where every grading interpreter must be
    /// present (`.github/docker/ci-image/Dockerfile`). Everywhere else the test
    /// reads as skipped, with this reason, instead of returning early in
    /// silence. `scripts/check-no-skipped-tests.sh` turns a skip on the CI
    /// image into a red job.
    static let ciOnly: ConditionTrait = .enabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "runs only in CI, where every interpreter must be present")

    /// Skips, visibly, when `Rscript` does not answer `--version`. The
    /// evaluator and the runner both spawn via `/usr/bin/env`, so the probe
    /// uses the same resolution.
    static let requiresRscript: ConditionTrait = .enabled("requires Rscript on PATH") {
        await cachedToolIsAvailable("Rscript")
    }

    /// Skips, visibly, when `octave-cli` does not answer `--version`.
    static let requiresOctave: ConditionTrait = .enabled("requires octave-cli on PATH") {
        await cachedToolIsAvailable("octave-cli")
    }
}

/// `@Test(.ciOnly)` resolves through `any TestTrait`, so the implicit-member
/// spelling needs the same `Trait where Self == ConditionTrait` extension the
/// built-in `.enabled(if:)` uses.
extension Trait where Self == ConditionTrait {
    static var ciOnly: Self { ConditionTrait.ciOnly }
    static var requiresRscript: Self { ConditionTrait.requiresRscript }
    static var requiresOctave: Self { ConditionTrait.requiresOctave }
}
