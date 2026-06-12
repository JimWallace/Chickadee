// RunnerCore/SuiteItem.swift
//
// The runtime view of one manifest test entry — exactly the fields the
// shared `executeSuites` loop needs, and nothing else. The authoring model
// (`TestSuiteEntry` in Core, with `generatedBy`, `sectionID`, `hint`, …) stays
// in Core; the worker projects each entry down to a `SuiteItem` before
// handing the list to the loop, and the browser runner builds `SuiteItem`s
// directly from the manifest JSON. Keeping this type minimal and
// Foundation-free is what lets the loop live in the wasm-safe leaf.

/// One test to run, in manifest order.
public struct SuiteItem: Sendable, Equatable {
    /// Filename of the runnable script in the workspace (e.g. `"test_bmi.py"`).
    public let script: String
    /// Tier the resulting outcome is tagged with.
    public let tier: TestTier
    /// Optional human-readable name shown to students. When nil or blank the
    /// loop falls back to the script filename without its extension.
    public let displayName: String?
    /// Script names of prerequisites that must have passed for this test to
    /// run. If any has not passed, the test is auto-failed with a
    /// `skippedPrerequisiteMessage`. Empty = no prerequisites.
    public let dependsOn: [String]
    /// Integer grade weight carried through onto the `TestOutcome`.
    public let points: Int

    public init(
        script: String,
        tier: TestTier,
        displayName: String? = nil,
        dependsOn: [String] = [],
        points: Int = 1
    ) {
        self.script = script
        self.tier = tier
        self.displayName = displayName
        self.dependsOn = dependsOn
        self.points = points
    }
}
