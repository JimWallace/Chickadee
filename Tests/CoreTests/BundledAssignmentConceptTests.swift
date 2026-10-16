// Tests/CoreTests/BundledAssignmentConceptTests.swift
//
// A course bundle carries an assignment's lab concept (docs/student-wardrobe.md,
// "Concept rings"). The key is optional: a bundle written before it was carried
// decodes with no concept, and the value is a plain string so a concept this
// instance does not know cannot fail the whole bundle.

import Foundation
import Testing

@testable import Core

@Suite struct BundledAssignmentConceptTests {

    private static func decode(_ json: String) throws -> BundledAssignment {
        try JSONDecoder().decode(BundledAssignment.self, from: Data(json.utf8))
    }

    @Test func theConceptRoundTrips() throws {
        let assignment = BundledAssignment(
            bundleID: "assign_1", title: "Loops Lab", dueAt: nil, sortOrder: nil,
            testSetupBundleID: "setup_1", concept: AssignmentConcept.loops.rawValue)
        let decoded = try JSONDecoder().decode(
            BundledAssignment.self, from: try JSONEncoder().encode(assignment))
        #expect(decoded.concept == "loops")
    }

    @Test func aBundleWithoutTheKeyDecodesWithNoConcept() throws {
        let decoded = try Self.decode(
            #"{"bundleID":"assign_1","title":"Lab","testSetupBundleID":"setup_1"}"#)
        #expect(decoded.concept == nil)
    }

    /// A newer bundle may carry a concept this instance does not know. It must
    /// still decode, so the import can treat it as no concept.
    @Test func anUnknownConceptStillDecodes() throws {
        let decoded = try Self.decode(
            #"{"bundleID":"assign_1","title":"Lab","testSetupBundleID":"setup_1","concept":"recursion"}"#)
        #expect(decoded.concept == "recursion")
        #expect(decoded.concept.flatMap(AssignmentConcept.init(rawValue:)) == nil)
    }
}
