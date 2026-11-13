// Tests/CoreTests/FHIRNdjsonProfileTests.swift
//
// `FHIRNdjsonProfile` (docs/fhir-datasets-plan.md §3 and §5): the structural
// checks a FHIR NDJSON dataset must pass, one refusal per case, and the summary
// the Data page shows.

import Testing

@testable import Core

@Suite struct FHIRNdjsonProfileTests {

    /// Two patients, three vital-sign Observations, one Encounter, one
    /// Practitioner, and an Observation whose patient is not in the file.
    static let feed =
        [
            #"{"resourceType":"Patient","id":"p1","gender":"female"}"#,
            #"{"resourceType":"Patient","id":"p2","gender":"male"}"#,
            #"{"resourceType":"Practitioner","id":"dr1"}"#,
            #"{"resourceType":"Encounter","id":"e1","subject":{"reference":"Patient/p1"}}"#,
            #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5","display":"Body temperature"}]},"#
                + #""valueQuantity":{"value":38.40,"unit":"Cel"}}"#,
            #"{"resourceType":"Observation","id":"o2","subject":{"reference":"Patient/p2"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]},"#
                + #""valueQuantity":{"value":36.9,"unit":"Cel"}}"#,
            #"{"resourceType":"Observation","id":"o3","subject":{"reference":"Patient/p2"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"59408-5","display":"SpO2"}]},"#
                + #""valueQuantity":{"value":91,"unit":"%"}}"#,
            #"{"resourceType":"Observation","id":"o4","subject":{"reference":"Patient/p9"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8867-4","display":"Heart rate"}]}}"#,
        ].joined(separator: "\n") + "\n"

    @Test func aWellFormedFeedIsCounted() throws {
        let summary = try FHIRNdjsonProfile.profile(Self.feed)
        #expect(summary.fhirVersion == "4.0.1")
        #expect(summary.resourceCount == 8)
        #expect(summary.patientCount == 2)
        #expect(
            summary.resourceTypes == [
                .init(resourceType: "Encounter", count: 1),
                .init(resourceType: "Observation", count: 4),
                .init(resourceType: "Patient", count: 2),
                .init(resourceType: "Practitioner", count: 1),
            ])
        #expect(summary.danglingPatientReferences == 1)
        #expect(summary.omittedCodeCount == 0)
    }

    /// Most used first, then by type, system and code; the first display seen
    /// is kept, and the units of every quantity with the code are listed.
    @Test func codesAreListedMostUsedFirst() throws {
        let codes = try FHIRNdjsonProfile.profile(Self.feed).codes
        #expect(codes.map(\.code) == ["8310-5", "59408-5", "8867-4"])
        let temperature = try #require(codes.first)
        #expect(temperature.count == 2)
        #expect(temperature.display == "Body temperature")
        #expect(temperature.units == ["Cel"])
        #expect(temperature.systemName == "LOINC")
        #expect(codes.last?.units.isEmpty == true)
    }

    @Test(
        "Code systems are named for students",
        arguments: [
            ("http://loinc.org", "LOINC"),
            ("http://snomed.info/sct", "SNOMED CT"),
            ("http://hl7.org/fhir/sid/icd-10", "ICD-10"),
            ("http://hl7.org/fhir/sid/icd-10-cm", "ICD-10-CM"),
            ("urn:oid:2.16.840.1.113883.6.96", "urn:oid:2.16.840.1.113883.6.96"),
        ])
    func systemNames(system: String, name: String) {
        #expect(FHIRDatasetSummary.CodeUse.name(ofSystem: system) == name)
    }

    @Test func blankLinesAndCarriageReturnsAreAccepted() throws {
        let text =
            "\r\n" + #"{"resourceType":"Patient","id":"p1"}"# + "\r\n  \r\n"
            + #"{"resourceType":"Patient","id":"p2"}"# + "\r"
        #expect(try FHIRNdjsonProfile.profile(text).patientCount == 2)
    }

    @Test func aCodeRepeatedInOneResourceCountsOnce() throws {
        let line =
            #"{"resourceType":"Condition","id":"c1","code":{"coding":["#
            + #"{"system":"http://snomed.info/sct","code":"386661006"},"#
            + #"{"system":"http://snomed.info/sct","code":"386661006"}]}}"#
        #expect(try FHIRNdjsonProfile.profile(line).codes.first?.count == 1)
    }

    @Test(
        "Each structural problem is refused with its line",
        arguments: [
            ("", FHIRDatasetIssue.empty),
            ("  \n\n", .empty),
            (#"{"resourceType":"Patient","id":"p1"}"# + "\n[1, 2]", .notAnObject(line: 2)),
            ("not json", .notAnObject(line: 1)),
            ("42", .notAnObject(line: 1)),
            (#"{"id":"p1"}"#, .missingResourceType(line: 1)),
            (#"{"resourceType":"","id":"p1"}"#, .missingResourceType(line: 1)),
            (#"{"resourceType":"Patient"}"#, .missingID(line: 1, resourceType: "Patient")),
            (#"{"resourceType":"Patient","id":7}"#, .missingID(line: 1, resourceType: "Patient")),
            (
                #"{"resourceType":"Patient","id":"p1"}"# + "\n\n" + #"{"resourceType":"Patient","id":"p1"}"#,
                .duplicateResource(resourceType: "Patient", id: "p1", line: 3, firstLine: 1)
            ),
        ])
    func refusals(text: String, expected: FHIRDatasetIssue) {
        #expect(throws: expected) { try FHIRNdjsonProfile.profile(text) }
    }

    /// The same id under two resource types is two resources.
    @Test func anIdMayRepeatAcrossTypes() throws {
        let text = #"{"resourceType":"Patient","id":"x"}"# + "\n" + #"{"resourceType":"Encounter","id":"x"}"#
        #expect(try FHIRNdjsonProfile.profile(text).resourceCount == 2)
    }

    @Test func messagesNameTheLine() {
        #expect(FHIRDatasetIssue.notAnObject(line: 12).description.contains("line 12"))
        #expect(
            FHIRDatasetIssue.duplicateResource(resourceType: "Patient", id: "p1", line: 9, firstLine: 2)
                .description == "line 9 repeats Patient/p1, which line 2 already holds.")
    }
}
