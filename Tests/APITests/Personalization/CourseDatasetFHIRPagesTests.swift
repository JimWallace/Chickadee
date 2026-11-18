// Tests/APITests/Personalization/CourseDatasetFHIRPagesTests.swift
//
// The pages of a FHIR NDJSON dataset (docs/fhir-datasets-plan.md §5, P3). The
// Datasets tab creates one by its format choice and saves its dictionary:
// the prose of each type and code, and the example resource. A new version
// and a bundle carry that prose. The student Data page shows the summary and
// the example, and the student's file is `mine.ndjson`, the same bytes the
// grader resolves. The Files panel offers to move an `.ndjson` support file
// into the library.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The download and the setup run `zip`, so the suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) struct CourseDatasetFHIRPagesTests {

    private static let feed =
        [
            #"{"resourceType":"Patient","id":"p1"}"#,
            #"{"resourceType":"Patient","id":"p2"}"#,
            #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8310-5","display":"Body temperature"}]},"#
                + #""valueQuantity":{"value":37.1,"unit":"Cel"}}"#,
            #"{"resourceType":"Observation","id":"o2","subject":{"reference":"Patient/p2"},"#
                + #""code":{"coding":[{"system":"http://loinc.org","code":"8867-4"}]}}"#,
        ].joined(separator: "\n") + "\n"

    private static let temperature = FHIRDatasetSummary.CodeKey(
        resourceType: "Observation", system: "http://loinc.org", code: "8310-5")

    private func blobs(_ app: Application) -> AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    private func createFeed(courseID: UUID, on app: Application) async throws -> APICourseDataset {
        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(
                name: "ED feed", slug: "ed-feed", provenance: "Generated", licence: "CC0", format: .fhirNdjson),
            upload: .init(filename: "ed_feed.ndjson", bytes: Data(Self.feed.utf8)), blobs: blobs(app), on: app.db
        ).dataset
        try await CourseDatasetService.setPublished(dataset, true, on: app.db)
        return dataset
    }

    /// A urlencoded POST with the Datasets tab's CSRF token; `fields` is the
    /// body after the token, already encoded. Returns the redirect target.
    private func formPOST(_ path: String, fields: String, cookie: String, on app: Application) async throws -> String {
        let csrf = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
        let body = "_csrf=\(urlEncode(csrf.token))&" + fields
        var location = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: csrf.cookie)
                req.headers.contentType = .urlEncodedForm
                var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
                buffer.writeString(body)
                req.body = .init(buffer: buffer)
            },
            afterResponse: { res in location = res.headers.first(name: .location) ?? "" })
        return location
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> HTTPResponseSnapshot {
        var snapshot = HTTPResponseSnapshot(status: .imATeapot, body: "", contentType: nil)
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                snapshot = HTTPResponseSnapshot(
                    status: res.status, body: res.body.string, contentType: res.headers.first(name: .contentType))
            })
        return snapshot
    }

    private struct HTTPResponseSnapshot {
        let status: HTTPStatus
        let body: String
        let contentType: String?
    }

    // MARK: - Create from the Datasets tab

    @Test func theUploadFormCreatesAFHIRDatasetByItsFormat() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let csrf = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
            let boundary = "----FHIRPagesBoundary"
            var text = ""
            for (name, value) in [("_csrf", csrf.token), ("name", "ED feed"), ("format", "fhirNdjson")] {
                text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            text +=
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ed_feed.ndjson\"\r\n"
                + "Content-Type: application/x-ndjson\r\n\r\n\(Self.feed)\r\n--\(boundary)--\r\n"
            var location = ""
            try await app.asyncTest(
                .POST, "/instructor/datasets",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: csrf.cookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                    buffer.writeString(text)
                    req.body = .init(buffer: buffer)
                },
                afterResponse: { res in location = res.headers.first(name: .location) ?? "" })
            #expect(location.contains("notice="), "\(location)")
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try #require(
                try await CourseDatasetService.find(courseID: courseID, slug: "ed-feed", on: app.db))
            #expect(dataset.format == .fhirNdjson)

            let page = try await get("/instructor/datasets/view?slug=ed-feed", cookie: cookie, on: app)
            #expect(page.status == .ok)
            #expect(page.body.contains("2 patients"))
            #expect(page.body.contains("typeDescriptions[]"))
            #expect(page.body.contains("8310-5"))
            #expect(!page.body.contains("columnDescriptions[]"))
        }
    }

    // MARK: - The dictionary

    @Test func theDictionaryFormSavesProseAndTheExample() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try await createFeed(courseID: courseID, on: app)
            let before = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db)?.summary)
            #expect(before.example?.id == "o1")

            let codes = before.codes.map { entry in
                "&codeTypes[]=\(urlEncode(entry.resourceType))&codeSystems[]=\(urlEncode(entry.system ?? ""))"
                    + "&codeCodes[]=\(urlEncode(entry.code))"
                    + "&codeDescriptions[]=\(entry.key == Self.temperature ? "Oral%2C%20at%20triage" : "")"
            }
            let location = try await formPOST(
                "/instructor/datasets/dictionary",
                fields: "slug=ed-feed&version=1"
                    + "&typeNames[]=Observation&typeDescriptions[]=Vital%20signs"
                    + "&typeNames[]=Patient&typeDescriptions[]=" + codes.joined()
                    + "&exampleType=Patient&exampleID=p2",
                cookie: cookie, on: app)
            #expect(location.contains("notice="), "\(location)")

            let after = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db)?.summary)
            #expect(after.resourceTypes.first { $0.resourceType == "Observation" }?.description == "Vital signs")
            #expect(after.resourceTypes.first { $0.resourceType == "Patient" }?.description == nil)
            #expect(after.codes.first { $0.key == Self.temperature }?.description == "Oral, at triage")
            #expect(
                after.example
                    == .init(resourceType: "Patient", id: "p2", json: #"{"resourceType":"Patient","id":"p2"}"#))
        }
    }

    @Test func anEntryTheFileLacksIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try await createFeed(courseID: courseID, on: app)
            for fields in [
                "slug=ed-feed&version=1&typeNames[]=Encounter&typeDescriptions[]=Visits",
                "slug=ed-feed&version=1&exampleType=Patient&exampleID=p9",
            ] {
                let location = try await formPOST(
                    "/instructor/datasets/dictionary", fields: fields, cookie: cookie, on: app)
                #expect(location.contains("error="), "\(fields) gave \(location)")
            }
            let summary = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db)?.summary)
            #expect(summary.example?.id == "o1")
        }
    }

    @Test func aNewVersionCarriesTheProseOfEveryEntryItStillHas() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try await createFeed(courseID: courseID, on: app)
            _ = try await CourseDatasetService.updateFHIRDictionary(
                dataset, version: 1,
                edit: .init(
                    types: [("Observation", "Vital signs")], codes: [(Self.temperature, "Oral")],
                    replacingOthers: true, example: ("Observation", "o2")),
                blobs: blobs(app), on: app.db)

            // Version 2 drops o2 and the heart rate code.
            let next = Self.feed.split(separator: "\n").prefix(3).joined(separator: "\n") + "\n"
            let added = try await CourseDatasetService.addVersion(
                to: dataset, upload: .init(filename: "ed_feed.ndjson", bytes: Data(next.utf8)), blobs: blobs(app),
                on: app.db)
            let summary = try #require(added.version.summary)
            #expect(summary.resourceTypes.first { $0.resourceType == "Observation" }?.description == "Vital signs")
            #expect(summary.codes.first { $0.key == Self.temperature }?.description == "Oral")
            // The picked example is gone, so the default stands.
            #expect(summary.example?.id == "o1")
        }
    }

    @Test func aBundleCarriesTheProse() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let dataset = try await createFeed(courseID: courseID, on: app)
            let edited = try await CourseDatasetService.updateFHIRDictionary(
                dataset, version: 1,
                edit: .init(
                    types: [("Patient", "One per arrival")], replacingOthers: false, example: ("Patient", "p1")),
                blobs: blobs(app), on: app.db)
            let bundled = try await CourseDatasetService.bundledLibrary(courseID: courseID, on: app.db)
            #expect(bundled.first?.versions.first?.summary == edited.summary)

            let target = try await makeTestCourse(on: app, code: "FHIRPG", name: "Imported").requireID()
            let feed = Data(Self.feed.utf8)
            try await CourseDatasetService.importBundledLibrary(
                bundled, courseID: target, bytes: { _ in feed }, blobs: blobs(app), on: app.db)
            let imported = try #require(
                try await CourseDatasetService.find(courseID: target, slug: "ed-feed", on: app.db))
            let row = try #require(try await CourseDatasetService.version(1, of: imported, on: app.db))
            #expect(row.summary == edited.summary)
        }
    }

    // MARK: - What students see

    /// TEST101's open assignment attaches the feed whole as `ed_feed.ndjson`.
    private func attachedSetup(on app: Application) async throws -> (courseKey: String, setupID: String) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        _ = try await createFeed(courseID: courseID, on: app)
        let setupID = "fpg_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("ed_feed.ndjson", Self.feed)])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,\
            "submissionMode":"uploadOnly",\
            "datasets":[{"file":"ed_feed.ndjson","kind":"rowSample",\
            "source":{"slug":"ed-feed","version":1},"format":"fhirNdjson","transforms":[]}]}
            """
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        _ = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Assignment 3", isOpen: true)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        return (course.urlKey, setupID)
    }

    @Test func theDataPageShowsTheSummaryAndLinksMineNdjson() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let (courseKey, setupID) = try await attachedSetup(on: app)
            let page = try await get("/data/\(courseKey)", cookie: cookie, on: app)
            #expect(page.status == .ok)
            #expect(page.body.contains("2 patients"))
            #expect(page.body.contains("Codes: LOINC"))
            #expect(page.body.contains("8310-5"))
            #expect(page.body.contains("Body temperature"))
            #expect(page.body.contains("Example resource"))
            #expect(page.body.contains("/testsetups/\(setupID)/data/ed_feed.ndjson/mine.ndjson"))
            #expect(!page.body.contains("mine.csv"))
        }
    }

    /// The student's file is the bytes the grader resolves, which for a FHIR
    /// file is the whole file, under either name.
    @Test func theStudentFileIsTheGradersBytes() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let (_, setupID) = try await attachedSetup(on: app)
            var bodies: [String] = []
            for name in ["mine.ndjson", "mine.csv"] {
                let file = try await get("/testsetups/\(setupID)/data/ed_feed.ndjson/\(name)", cookie: cookie, on: app)
                #expect(file.status == .ok, "\(name)")
                #expect(file.body == Self.feed, "\(name)")
                #expect(file.contentType == "application/fhir+ndjson; charset=utf-8", "\(name)")
                bodies.append(file.body)
            }
            // The grader's call, once the download has unpacked the shared
            // copy. Any seed gives the whole file.
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let manifest = try #require(setup.decodedManifest())
            let graded = DatasetResolver.resolve(
                manifest: manifest, seedHex: String(repeating: "a", count: 64), courseSeedHex: nil,
                sourceDirectory: app.testSetupsDirectory + "shared/\(setupID)/")
            #expect(bodies.allSatisfy { $0 == graded?["ed_feed.ndjson"] })
        }
    }
}
