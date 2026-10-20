// Tests/APITests/Pages/InstructorDatasetsAuditTests.swift
//
// Each write on the web Datasets tab that succeeds records one audit row
// (#2724): create, add version, metadata, dictionary, publish and delete. The
// row names the dataset and its course, and nothing from the file. A write
// that the service refuses records no row.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct InstructorDatasetsAuditTests {

    private static let firstCSV = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n"
    private static let secondCSV = "id,ward,systolic\n1,A,121\n2,B,130\n"

    // MARK: - Helpers

    /// A dataset in the shared TEST101 course, made through the service, so
    /// it records no audit row of its own.
    @discardableResult
    private func seedDataset(on app: Application, slug: String = "cases") async throws -> APICourseDataset {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        return try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: slug),
            upload: .init(filename: "cases.csv", bytes: Data(Self.firstCSV.utf8)),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db
        ).dataset
    }

    private func rows(_ action: AuditAction, on app: Application) async throws -> [APIAuditLogEntry] {
        try await APIAuditLogEntry.query(on: app.db).filter(\.$action == action.rawValue).all()
    }

    /// The one row of `action`, after a check of the fields every dataset
    /// row shares.
    private func onlyRow(
        _ action: AuditAction, slug: String, on app: Application
    ) async throws -> [String: String] {
        let found = try await rows(action, on: app)
        #expect(found.count == 1)
        let row = try #require(found.first)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        #expect(row.targetType == AuditTargetType.dataset.rawValue)
        #expect(row.courseID == courseID)
        #expect(row.actorUsername != nil)
        let metadata = row.metadataDictionary
        #expect(metadata["dataset"] == slug)
        #expect(metadata["course_id"] == courseID.uuidString)
        #expect(metadata["title"] == "Ward cases")
        return metadata
    }

    private func formPOST(
        _ path: String, fields: [String: String], cookie: String, on app: Application
    ) async throws -> String {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = csrf
        var location = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location) ?? ""
            })
        return location
    }

    private func uploadPOST(
        _ path: String, fields: [String: String], csv: String, cookie: String, on app: Application
    ) async throws -> String {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
        let boundary = "----DatasetsAuditBoundary"
        var text = ""
        for (name, value) in fields.merging(["_csrf": csrf], uniquingKeysWith: { first, _ in first }) {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        text +=
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cases.csv\"\r\n"
            + "Content-Type: text/csv\r\n\r\n\(csv)\r\n--\(boundary)--\r\n"
        var location = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
                buffer.writeString(text)
                req.body = .init(buffer: buffer)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location) ?? ""
            })
        return location
    }

    // MARK: - One row per write

    @Test func createRecordsOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsCourseTA("dsaudit_ta", on: app)
            let location = try await uploadPOST(
                "/instructor/datasets", fields: ["name": "Ward cases", "slug": "cases"], csv: Self.firstCSV,
                cookie: cookie, on: app)
            #expect(location.contains("notice="))

            let metadata = try await onlyRow(.datasetCreated, slug: "cases", on: app)
            #expect(metadata["version"] == "1")
            #expect(Set(metadata.keys) == ["dataset", "title", "course_id", "version"])
        }
    }

    @Test func addVersionRecordsOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let location = try await uploadPOST(
                "/instructor/datasets/versions", fields: ["slug": "cases", "note": "Corrected"],
                csv: Self.secondCSV, cookie: cookie, on: app)
            #expect(location.contains("notice="))

            let metadata = try await onlyRow(.datasetVersionAdded, slug: "cases", on: app)
            #expect(metadata["version"] == "2")
        }
    }

    @Test func metadataRecordsOneRowWithoutTheText() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let location = try await formPOST(
                "/instructor/datasets/metadata",
                fields: [
                    "slug": "cases", "name": "Ward cases", "description": "Admissions by ward",
                    "provenance": "Hospital extract", "licence": "Course use only",
                ],
                cookie: cookie, on: app)
            #expect(location.contains("notice="))

            let metadata = try await onlyRow(.datasetMetadataChanged, slug: "cases", on: app)
            #expect(Set(metadata.keys) == ["dataset", "title", "course_id"])
        }
    }

    @Test func dictionaryRecordsOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let csrf = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
            // Repeated keys, as the browser sends the dictionary form.
            let body =
                "_csrf=\(urlEncode(csrf.token))&slug=cases&version=1"
                + "&columnNames[]=id&columnDescriptions[]=&columnUnits[]="
                + "&columnNames[]=ward&columnDescriptions[]=Hospital%20ward&columnUnits[]="
                + "&columnNames[]=systolic&columnDescriptions[]=Systolic%20pressure&columnUnits[]=mmHg"
            try await app.asyncTest(
                .POST, "/instructor/datasets/dictionary",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: csrf.cookie)
                    req.headers.contentType = .urlEncodedForm
                    var buffer = ByteBufferAllocator().buffer(capacity: body.utf8.count)
                    buffer.writeString(body)
                    req.body = .init(buffer: buffer)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location)?.contains("notice=") == true)
                })

            let metadata = try await onlyRow(.datasetDictionaryChanged, slug: "cases", on: app)
            #expect(metadata["version"] == "1")
        }
    }

    @Test func publishAndUnpublishEachRecordOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let dataset = try await seedDataset(on: app)
            dataset.provenance = "Hospital extract"
            dataset.licence = "Course use only"
            try await dataset.save(on: app.db)

            _ = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "1"], cookie: cookie, on: app)
            let published = try await onlyRow(.datasetVisibilityChanged, slug: "cases", on: app)
            #expect(published["published"] == "true")

            _ = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "0"], cookie: cookie, on: app)
            let found = try await rows(.datasetVisibilityChanged, on: app)
            #expect(found.map(\.metadataDictionary).compactMap { $0["published"] }.sorted() == ["false", "true"])
        }
    }

    @Test func deleteRecordsOneRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let dataset = try await seedDataset(on: app)
            let location = try await formPOST(
                "/instructor/datasets/delete", fields: ["slug": "cases"], cookie: cookie, on: app)
            #expect(location.hasPrefix("/instructor/datasets?notice="))

            _ = try await onlyRow(.datasetDeleted, slug: "cases", on: app)
            let row = try #require(try await rows(.datasetDeleted, on: app).first)
            #expect(row.targetID == dataset.id?.uuidString)
        }
    }

    // MARK: - A refused write

    /// Publishing needs a provenance and a licence, so the seeded dataset is
    /// refused, and nothing changed to record.
    @Test func aRefusedWriteRecordsNoRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let location = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "1"], cookie: cookie, on: app)
            #expect(location.contains("error="))
            #expect(try await rows(.datasetVisibilityChanged, on: app).isEmpty)
        }
    }

    // MARK: - Display

    @Test(arguments: [
        AuditAction.datasetCreated, .datasetVersionAdded, .datasetMetadataChanged, .datasetDictionaryChanged,
        .datasetVisibilityChanged, .datasetDeleted,
    ])
    func datasetActionsAreCourseActionsThatSucceeded(_ action: AuditAction) {
        #expect(action.category == .courses)
        #expect(action.outcome == .ok)
        #expect(action.rawValue.hasPrefix("dataset."))
    }
}
