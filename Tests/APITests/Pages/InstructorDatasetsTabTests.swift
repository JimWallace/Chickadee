// Tests/APITests/Pages/InstructorDatasetsTabTests.swift
//
// The instructor Datasets tab (docs/datasets-course-library.md §4.5). Only
// course staff read or write. A TA creates a dataset from an upload, with a
// slug made from the name. A refused upload comes back as an error.
// Publishing needs a provenance and a licence. The dictionary and a new
// version save, and each version downloads its own bytes. An attached dataset
// cannot be deleted. A slug of another course is not found at any route, and
// an archived course refuses writes.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct InstructorDatasetsTabTests {

    private static let firstCSV = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n"
    private static let secondCSV = "id,ward,systolic\n1,A,121\n2,B,130\n"

    // MARK: - Helpers

    private func blobs(_ app: Application) -> AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    /// A dataset in the shared TEST101 course, made through the service.
    @discardableResult
    private func seedDataset(on app: Application, slug: String = "cases") async throws -> APICourseDataset {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        return try await seedDataset(courseID: courseID, slug: slug, on: app)
    }

    @discardableResult
    private func seedDataset(courseID: UUID, slug: String, on app: Application) async throws -> APICourseDataset {
        try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: slug),
            upload: .init(filename: "cases.csv", bytes: Data(Self.firstCSV.utf8)), blobs: blobs(app), on: app.db
        ).dataset
    }

    private func reload(_ slug: String, on app: Application) async throws -> APICourseDataset {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        return try #require(try await CourseDatasetService.find(courseID: courseID, slug: slug, on: app.db))
    }

    /// A form POST with the page's CSRF token. Returns the status and the
    /// redirect target.
    private func formPOST(
        _ path: String, fields: [String: String], cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, location: String) {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = csrf
        var result: (HTTPStatus, String) = (.imATeapot, "")
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                result = (res.status, res.headers.first(name: .location) ?? "")
            })
        return result
    }

    /// A multipart POST of one CSV file plus text fields.
    private func uploadPOST(
        _ path: String, fields: [String: String], filename: String, csv: String, cookie: String,
        on app: Application
    ) async throws -> (status: HTTPStatus, location: String) {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/datasets", cookie: cookie, on: app)
        let boundary = "----DatasetsTabBoundary"
        var text = ""
        for (name, value) in fields.merging(["_csrf": csrf], uniquingKeysWith: { first, _ in first }) {
            text += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        text +=
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: text/csv\r\n\r\n\(csv)\r\n--\(boundary)--\r\n"
        var result: (HTTPStatus, String) = (.imATeapot, "")
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
                result = (res.status, res.headers.first(name: .location) ?? "")
            })
        return result
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.imATeapot, "")
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    // MARK: - Access

    @Test func studentCannotOpenTheDatasetsTab() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let (status, _) = try await get("/instructor/datasets", cookie: cookie, on: app)
            #expect(status == .forbidden)
        }
    }

    @Test func aStudentCannotWrite() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedDataset(on: app)
            let cookie = try await arLoginAsStudent(on: app)
            let post = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "1"], cookie: cookie, on: app)
            #expect(post.status == .forbidden)
        }
    }

    /// Every route that names a dataset looks the slug up in the active
    /// course only.
    @Test func aSlugOfAnotherCourseIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let other = try await makeTestCourse(on: app, code: "DSTAB2", name: "Other").requireID()
            try await seedDataset(courseID: other, slug: "elsewhere", on: app)

            for path in ["/instructor/datasets/view?slug=elsewhere", "/instructor/datasets/download?slug=elsewhere"] {
                let (status, _) = try await get(path, cookie: cookie, on: app)
                #expect(status == .notFound, "\(path)")
            }
            let writes: [(String, [String: String])] = [
                ("/instructor/datasets/metadata", ["slug": "elsewhere", "name": "Taken"]),
                ("/instructor/datasets/dictionary", ["slug": "elsewhere"]),
                ("/instructor/datasets/publish", ["slug": "elsewhere", "published": "0"]),
                ("/instructor/datasets/delete", ["slug": "elsewhere"]),
            ]
            for (path, fields) in writes {
                let post = try await formPOST(path, fields: fields, cookie: cookie, on: app)
                #expect(post.status == .notFound, "\(path)")
            }
            let upload = try await uploadPOST(
                "/instructor/datasets/versions", fields: ["slug": "elsewhere"], filename: "cases.csv",
                csv: Self.secondCSV, cookie: cookie, on: app)
            #expect(upload.status == .notFound)
            #expect(try await CourseDatasetService.find(courseID: other, slug: "elsewhere", on: app.db) != nil)
        }
    }

    /// An archived course drops out of the active course, so the
    /// `/instructor` gate refuses the write before the route runs.
    @Test func anArchivedCourseRefusesWrites() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let course = try #require(
                try await APICourse.find(try await app.testCourseID(enrollmentMode: .auto), on: app.db))
            course.isArchived = true
            try await course.save(on: app.db)

            let post = try await formPOST(
                "/instructor/datasets/metadata", fields: ["slug": "cases", "name": "Renamed"], cookie: cookie,
                on: app)
            #expect(post.status == .forbidden)
            #expect(try await reload("cases", on: app).name == "Ward cases")
        }
    }

    @Test func aVersionThatIsNotANumberIsABadRequest() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let (status, _) = try await get(
                "/instructor/datasets/download?slug=cases&version=latest", cookie: cookie, on: app)
            #expect(status == .badRequest)
        }
    }

    // MARK: - Create

    @Test func aTACreatesADatasetWithASlugFromTheName() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsCourseTA("dstab_ta", on: app)
            let post = try await uploadPOST(
                "/instructor/datasets", fields: ["name": "Ward Cases (2026)", "note": "First extract"],
                filename: "cases.csv", csv: Self.firstCSV, cookie: cookie, on: app)
            #expect(post.status == .seeOther)
            #expect(post.location.hasPrefix("/instructor/datasets/view?slug=ward-cases-2026"))

            let dataset = try await reload("ward-cases-2026", on: app)
            #expect(dataset.name == "Ward Cases (2026)")
            #expect(!dataset.isPublished)
            let version = try #require(try await CourseDatasetService.version(1, of: dataset, on: app.db))
            #expect(version.note == "First extract")
            #expect(version.rowCount == 3)

            let (status, html) = try await get("/instructor/datasets", cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(html.contains("Ward Cases (2026)"))
            #expect(html.contains("v1 · 3 rows"))
        }
    }

    @Test func aRefusedUploadComesBackAsAnError() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let post = try await uploadPOST(
                "/instructor/datasets", fields: ["name": "Notes", "slug": "notes"], filename: "notes.txt",
                csv: Self.firstCSV, cookie: cookie, on: app)
            #expect(post.status == .seeOther)
            #expect(post.location.hasPrefix("/instructor/datasets?error="))
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            #expect(try await CourseDatasetService.find(courseID: courseID, slug: "notes", on: app.db) == nil)
        }
    }

    // MARK: - Edit

    @Test func publishingNeedsAProvenanceAndALicence() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)

            let refused = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "1"], cookie: cookie, on: app)
            #expect(refused.location.contains("error="))
            #expect(try await reload("cases", on: app).isPublished == false)

            let saved = try await formPOST(
                "/instructor/datasets/metadata",
                fields: [
                    "slug": "cases", "name": "Ward cases", "description": "Admissions by ward",
                    "provenance": "Hospital extract", "licence": "Course use only",
                ],
                cookie: cookie, on: app)
            #expect(saved.location.contains("notice="))
            let published = try await formPOST(
                "/instructor/datasets/publish", fields: ["slug": "cases", "published": "1"], cookie: cookie, on: app)
            #expect(published.location.contains("notice="))

            let dataset = try await reload("cases", on: app)
            #expect(dataset.isPublished)
            #expect(dataset.datasetDescription == "Admissions by ward")
        }
    }

    @Test func theDictionarySavesTheProseOfEachColumn() async throws {
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("notice=") == true)
                })

            let version = try #require(
                try await CourseDatasetService.version(1, of: reload("cases", on: app), on: app.db))
            #expect(version.columns.map(\.description) == [nil, "Hospital ward", "Systolic pressure"])
            #expect(version.columns.map(\.unit) == [nil, nil, "mmHg"])
            #expect(version.columns.map(\.valueType) == [.integer, .text, .integer])
        }
    }

    @Test func aNewVersionUploadsAndEachVersionDownloadsItsOwnBytes() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            let post = try await uploadPOST(
                "/instructor/datasets/versions", fields: ["slug": "cases", "note": "Corrected readings"],
                filename: "cases.csv", csv: Self.secondCSV, cookie: cookie, on: app)
            #expect(post.location.contains("notice="))
            #expect(try await reload("cases", on: app).currentVersion == 2)

            for (version, csv) in [(1, Self.firstCSV), (2, Self.secondCSV)] {
                try await app.asyncTest(
                    .GET, "/instructor/datasets/download?slug=cases&version=\(version)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        #expect(res.status == .ok)
                        #expect(res.body.string == csv)
                        #expect(
                            res.headers.first(name: .contentDisposition)
                                == "attachment; filename=\"cases-v\(version).csv\"")
                    })
            }

            let (_, html) = try await get("/instructor/datasets/view?slug=cases", cookie: cookie, on: app)
            #expect(html.contains("Corrected readings"))
        }
    }

    @Test func anAttachedDatasetCannotBeDeleted() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await seedDataset(on: app)
            try await seedDataset(on: app, slug: "unused")
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let manifest = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,\
                "datasets":[{"file":"cases.csv","sampleSize":2,"source":{"slug":"cases","version":1},\
                "transforms":[]}]}
                """
            try await makeTestSetup(
                on: app, id: "dstab_attached", courseID: courseID, manifest: manifest, withNotebook: false,
                withZip: false)
            _ = try await makeTestAssignment(
                on: app, testSetupID: "dstab_attached", courseID: courseID, title: "Lab 2")

            let (_, html) = try await get("/instructor/datasets/view?slug=cases", cookie: cookie, on: app)
            #expect(html.contains("Lab 2"))
            let (_, list) = try await get("/instructor/datasets", cookie: cookie, on: app)
            #expect(list.contains("1 assignment"))
            #expect(list.contains("Not attached"))

            let refused = try await formPOST(
                "/instructor/datasets/delete", fields: ["slug": "cases"], cookie: cookie, on: app)
            #expect(refused.location.contains("error="))
            #expect(try await CourseDatasetService.find(courseID: courseID, slug: "cases", on: app.db) != nil)

            let deleted = try await formPOST(
                "/instructor/datasets/delete", fields: ["slug": "unused"], cookie: cookie, on: app)
            #expect(deleted.location.hasPrefix("/instructor/datasets?notice="))
            #expect(try await CourseDatasetService.find(courseID: courseID, slug: "unused", on: app.db) == nil)
        }
    }

    // MARK: - Slug suggestion

    @Test(arguments: [
        ("VitalDB cases", "vitaldb-cases"),
        ("  NHANES: blood pressure (2017)  ", "nhanes-blood-pressure-2017"),
        ("Ünïcode only", "n-code-only"),
        ("---", ""),
    ])
    func aSlugIsMadeFromTheName(name: String, slug: String) {
        #expect(CourseDatasetService.suggestedSlug(from: name) == slug)
    }
}
