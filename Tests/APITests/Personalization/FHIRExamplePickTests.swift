// Tests/APITests/Personalization/FHIRExamplePickTests.swift
//
// The example pick on a FHIR dataset's page (docs/fhir-datasets-plan.md §5),
// from a check in the running app. A pick that the file lacks is refused
// with a message that says so, and a resource too long to show with a
// message that says that; a refused pick keeps the descriptions saved beside
// it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct FHIRExamplePickTests {

    private static let feed =
        [
            #"{"resourceType":"Patient","id":"p1"}"#,
            #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5"}]}}"#,
        ].joined(separator: "\n") + "\n"

    @Test func aMissingAndATooLongResourceAreRefusedApart() throws {
        let long =
            #"{"resourceType":"Patient","id":"big","note":""#
            + String(repeating: "x", count: FHIRDatasetSummary.maxExampleBytes) + #""}"#
        let text = Self.feed + long + "\n"
        let summary = try FHIRNdjsonProfile.profile(text)
        #expect(throws: FHIRDictionaryEditIssue.unknownExample(resourceType: "Patient", id: "p9")) {
            try summary.withExample(resourceType: "Patient", id: "p9", in: text)
        }
        #expect(throws: FHIRDictionaryEditIssue.exampleTooLong(resourceType: "Patient", id: "big")) {
            try summary.withExample(resourceType: "Patient", id: "big", in: text)
        }
        #expect(!FHIRDictionaryEditIssue.unknownExample(resourceType: "Patient", id: "p9").description.contains("KB"))
    }

    @Test func aRefusedPickKeepsTheDescriptions() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try await CourseDatasetService.create(
                courseID: courseID, dataset: .init(name: "ED feed", slug: "ed-feed", format: .fhirNdjson),
                upload: .init(filename: "ed_feed.ndjson", bytes: Data(Self.feed.utf8)),
                blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db
            ).dataset
            let csrf = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
            let body =
                "_csrf=\(urlEncode(csrf.token))&slug=ed-feed&version=1"
                + "&typeNames[]=Observation&typeDescriptions[]=Vital%20signs"
                + "&typeNames[]=Patient&typeDescriptions[]="
                + "&codeTypes[]=Observation&codeSystems[]=http%3A%2F%2Floinc.org&codeCodes[]=8310-5"
                + "&codeDescriptions[]=Oral&exampleType=Patient&exampleID=p9"
            var location = ""
            try await app.asyncTest(
                .POST, "/instructor/datasets/dictionary",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: csrf.cookie)
                    req.headers.contentType = .urlEncodedForm
                    var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    req.body = .init(buffer: buffer)
                },
                afterResponse: { res in location = res.headers.first(name: .location) ?? "" })
            let error = try #require(location.removingPercentEncoding)
            #expect(error.contains("The descriptions are saved."), "\(error)")
            #expect(error.contains("no Patient with the id p9"), "\(error)")

            let summary = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db)?.summary)
            #expect(summary.resourceTypes.first { $0.resourceType == "Observation" }?.description == "Vital signs")
            #expect(summary.codes.first?.description == "Oral")
            #expect(summary.example?.id == "o1")
        }
    }
}
