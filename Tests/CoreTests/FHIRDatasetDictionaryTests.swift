// Tests/CoreTests/FHIRDatasetDictionaryTests.swift
//
// The FHIR data dictionary (docs/fhir-datasets-plan.md §5): the profile picks
// the first Observation as the example, an edit names only entries the file
// has, a new file keeps the prose of the entries it still has, and the
// example keeps the file's own line.

import Foundation
import Testing

@testable import Core

@Suite struct FHIRDatasetDictionaryTests {

    private static let lines = [
        #"{"resourceType":"Patient","id":"p1"}"#,
        #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
            + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
        #"{"resourceType":"Observation","id":"o2","subject":{"reference":"Patient/p1"},"#
            + #""code":{"coding":[{"system":"","code":"local-1"}]}}"#,
    ]
    private static let text = lines.joined(separator: "\n") + "\n"
    private static let loinc = FHIRDatasetSummary.CodeKey(
        resourceType: "Observation", system: "http://loinc.org", code: "8310-5")

    private func summary(_ text: String = Self.text) throws -> FHIRDatasetSummary {
        try FHIRNdjsonProfile.profile(text)
    }

    @Test func theProfilePicksTheFirstObservationLineAsItIs() throws {
        #expect(try summary().example == .init(resourceType: "Observation", id: "o1", json: Self.lines[1]))
    }

    @Test func aFileWithNoObservationShowsItsFirstResource() throws {
        #expect(try summary(Self.lines[0]).example?.id == "p1")
    }

    @Test func aResourceTooLongToShowIsNotTheExample() throws {
        let long =
            #"{"resourceType":"Observation","id":"big","note":""#
            + String(repeating: "x", count: FHIRDatasetSummary.maxExampleBytes) + #""}"#
        #expect(try summary(long + "\n" + Self.lines[0]).example?.id == "p1")
    }

    @Test func anEmptySystemReadsAsNone() throws {
        #expect(try summary().codes.contains { $0.code == "local-1" && $0.system == nil })
    }

    @Test func anEditNamesOnlyEntriesTheFileHas() throws {
        let base = try summary()
        #expect(throws: FHIRDictionaryEditIssue.unknownResourceType("Encounter")) {
            try base.withNotes(types: [("Encounter", "Visits")], codes: [], replacingOthers: false)
        }
        let missing = FHIRDatasetSummary.CodeKey(resourceType: "Observation", system: nil, code: "8310-5")
        #expect(throws: FHIRDictionaryEditIssue.unknownCode(missing)) {
            try base.withNotes(types: [], codes: [(missing, "x")], replacingOthers: false)
        }
        #expect(throws: FHIRDictionaryEditIssue.describedTwice("Patient")) {
            try base.withNotes(types: [("Patient", "a"), ("Patient", "b")], codes: [], replacingOthers: false)
        }
        let long = String(repeating: "x", count: FHIRDatasetSummary.maxDescriptionCharacters + 1)
        #expect(throws: FHIRDictionaryEditIssue.tooLong("Observation 8310-5 (LOINC)")) {
            try base.withNotes(types: [], codes: [(Self.loinc, long)], replacingOthers: false)
        }
        #expect(throws: FHIRDictionaryEditIssue.unknownExample(resourceType: "Patient", id: "p9")) {
            try base.withExample(resourceType: "Patient", id: "p9", in: Self.text)
        }
    }

    @Test func anEditByNameKeepsTheOtherEntriesAndAFullEditClearsThem() throws {
        let first = try summary().withNotes(
            types: [("Patient", "Arrivals")], codes: [(Self.loinc, " Oral ")], replacingOthers: true)
        #expect(first.codes.first { $0.key == Self.loinc }?.description == "Oral")

        let byName = try first.withNotes(types: [("Observation", "Vitals")], codes: [], replacingOthers: false)
        #expect(byName.resourceTypes.first { $0.resourceType == "Patient" }?.description == "Arrivals")
        #expect(byName.codes.first { $0.key == Self.loinc }?.description == "Oral")

        let full = try first.withNotes(types: [("Observation", "Vitals")], codes: [], replacingOthers: true)
        #expect(full.resourceTypes.first { $0.resourceType == "Patient" }?.description == nil)
        #expect(full.codes.first { $0.key == Self.loinc }?.description == nil)

        let blank = try first.withNotes(types: [("Patient", "  ")], codes: [], replacingOthers: false)
        #expect(blank.resourceTypes.first { $0.resourceType == "Patient" }?.description == nil)
    }

    @Test func aNewFileKeepsTheProseAndThePickItStillHas() throws {
        let old = try summary()
            .withNotes(types: [("Patient", "Arrivals")], codes: [(Self.loinc, "Oral")], replacingOthers: true)
            .withExample(resourceType: "Patient", id: "p1", in: Self.text)
        // The new file drops o2 and changes p1's line.
        let newPatient = #"{"resourceType":"Patient","id":"p1","gender":"female"}"#
        let newText = [newPatient, Self.lines[1]].joined(separator: "\n")
        let carried = try summary(newText).carryingNotes(from: old, text: newText)
        #expect(carried.resourceTypes.first { $0.resourceType == "Patient" }?.description == "Arrivals")
        #expect(carried.codes.first { $0.key == Self.loinc }?.description == "Oral")
        #expect(carried.example == .init(resourceType: "Patient", id: "p1", json: newPatient))

        // A pick the new file lacks gives way to the new default.
        let gone = try summary().withExample(resourceType: "Observation", id: "o2", in: Self.text)
        #expect(try summary(newText).carryingNotes(from: gone, text: newText).example?.id == "o1")
    }

    @Test func theExampleTextIsReindentedWithItsKeyOrder() throws {
        let text = try #require(try summary(Self.lines[0]).exampleText)
        #expect(text == "{\n  \"resourceType\": \"Patient\",\n  \"id\": \"p1\"\n}")
    }

    @Test func aSummaryStoredBeforeTheDictionaryDecodesWithNoProse() throws {
        let stored =
            #"{"codes":[],"danglingPatientReferences":0,"fhirVersion":"4.0.1","omittedCodeCount":0,"#
            + #""patientCount":1,"resourceCount":1,"resourceTypes":[{"count":1,"resourceType":"Patient"}]}"#
        let decoded = try JSONDecoder().decode(FHIRDatasetSummary.self, from: Data(stored.utf8))
        #expect(decoded.example == nil)
        #expect(decoded.resourceTypes.first?.description == nil)
    }
}
