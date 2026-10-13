// Core/TestSettings.swift
//
// The per-test settings that four manifest types each declare: a suite
// entry, a family's defaults, a family case (as overrides) and a notebook
// check.  Each type keeps its own stored fields and its own JSON keys,
// because their decode defaults and encode rules differ and the stored bytes
// feed `spec_hash` and the runner cache key.  `TestSettings` is the one value
// that code passes between them.  See docs/manifest-format-v2.md, D2.

/// The settings that decide how one test is weighted, timed and shown.
public struct TestSettings: Equatable, Sendable {
    public var tier: TestTier
    /// The grade weight.
    public var points: Int
    /// The hint shown when the test fails.  nil means no hint.
    public var hint: String?
    /// The per-test time limit in seconds.  nil means the assignment default.
    public var timeLimitSeconds: Int?
    /// How much of a failure the student sees.  nil means full.
    public var failureDetail: FailureDetail?

    public init(
        tier: TestTier, points: Int, hint: String? = nil,
        timeLimitSeconds: Int? = nil, failureDetail: FailureDetail? = nil
    ) {
        self.tier = tier
        self.points = points
        self.hint = hint
        self.timeLimitSeconds = timeLimitSeconds
        self.failureDetail = failureDetail
    }
}

extension TestSuiteEntry {
    /// This entry's settings.  The setter writes the five stored fields.
    public var settings: TestSettings {
        get {
            TestSettings(
                tier: tier, points: points, hint: hint,
                timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail)
        }
        set {
            tier = newValue.tier
            points = newValue.points
            hint = newValue.hint
            timeLimitSeconds = newValue.timeLimitSeconds
            failureDetail = newValue.failureDetail
        }
    }
}

extension PatternDefaults {
    /// The family-level settings that a case without overrides gets.
    public var settings: TestSettings {
        TestSettings(
            tier: tier, points: points, hint: hint,
            timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail)
    }
}

extension PatternCase {
    /// This case's settings: each override when it is set, else the family
    /// default.  Each field follows its own `resolved*(defaults:)` rule.
    public func resolvedSettings(defaults: PatternDefaults) -> TestSettings {
        TestSettings(
            tier: resolvedTier(defaults: defaults),
            points: resolvedPoints(defaults: defaults),
            hint: resolvedHint(defaults: defaults),
            timeLimitSeconds: resolvedTimeLimit(defaults: defaults),
            failureDetail: resolvedFailureDetail(defaults: defaults))
    }
}

extension NotebookCheck {
    /// This check's settings.
    public var settings: TestSettings {
        TestSettings(
            tier: tier, points: points, hint: hint,
            timeLimitSeconds: timeLimitSeconds, failureDetail: failureDetail)
    }
}
