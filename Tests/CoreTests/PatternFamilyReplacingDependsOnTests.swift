// Tests/CoreTests/PatternFamilyReplacingDependsOnTests.swift
//
// `replacingDependsOn` must preserve every field but the one it replaces.
//
// It exists because the suite-edit path used to do that copy inline, listing
// the fields it knew about, and a field added later was silently dropped. That
// is not hypothetical: it happened to `variables`, and the symptom was an
// `argVarRefs` reference failing validation on the next save of a family the
// author had not touched. `referenceImplementation` would have been the second.
//
// A hand-written field-by-field assertion here would have exactly the same
// blind spot as the code it guards, so this reflects over the stored
// properties instead: a new field is covered the day it is added, without
// anyone remembering to cover it.

import Foundation
import Testing

@testable import Core

@Suite struct PatternFamilyReplacingDependsOnTests {

    /// A family with every field set to something distinguishable, so a
    /// dropped one shows up as a difference rather than as two empty values
    /// that happen to match.
    private static let populated = PatternFamily(
        id: "fam",
        name: "Family",
        kind: .differential,
        functionName: "classify",
        paramNames: ["x", "y"],
        defaults: PatternDefaults(
            tier: .release, points: 3, hint: "a hint", tolerance: 0.25, timeLimitSeconds: 7),
        cases: [
            PatternCase(key: "01", label: "case one", args: [.int(1)], expected: .null)
        ],
        variables: [FamilyVariable(name: "threshold", value: .double(18.5))],
        dependsOn: ["family:other"],
        referenceImplementation: "def ck_ref_classify(x, y):\n    return 1"
    )

    @Test func everyStoredPropertyButDependsOnSurvivesTheCopy() throws {
        let copy = Self.populated.replacingDependsOn(["family:replaced"])
        #expect(copy.dependsOn == ["family:replaced"])

        let originalFields = Mirror(reflecting: Self.populated).children
        let copiedFields = Mirror(reflecting: copy).children
        #expect(
            originalFields.count > 8,
            "reflection found almost nothing — has PatternFamily stopped being a struct?")
        #expect(originalFields.count == copiedFields.count)

        for (original, copied) in zip(originalFields, copiedFields) {
            let label = try #require(original.label)
            if label == "dependsOn" { continue }
            #expect(
                String(describing: original.value) == String(describing: copied.value),
                """
                replacingDependsOn dropped or changed `\(label)`.
                  before: \(original.value)
                  after:  \(copied.value)
                Add it to the copy in Sources/Core/Models/PatternFamily.swift — the suite-edit
                path uses this whenever the editor sends a row-level dependency, so a dropped
                field is lost on an ordinary save of a family nobody edited.
                """)
        }
    }

    /// The populated fixture is only meaningful if its fields are actually
    /// non-default. A future refactor that made one of them empty would leave
    /// the reflection test comparing nothing to nothing.
    @Test func theFixtureLeavesNoFieldAtItsDefault() {
        #expect(!Self.populated.paramNames.isEmpty)
        #expect(!Self.populated.cases.isEmpty)
        #expect(!Self.populated.variables.isEmpty)
        #expect(!Self.populated.dependsOn.isEmpty)
        #expect(Self.populated.referenceImplementation?.isEmpty == false)
        #expect(Self.populated.defaults.tolerance != nil)
        #expect(Self.populated.defaults.timeLimitSeconds != nil)
        #expect(Self.populated.defaults.hint != nil)
    }
}
