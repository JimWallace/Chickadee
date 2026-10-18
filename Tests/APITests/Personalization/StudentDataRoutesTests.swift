// Tests/APITests/Personalization/StudentDataRoutesTests.swift
//
// What students see of the course dataset library
// (docs/datasets-course-library.md §4.6). The Data page lists published
// datasets to a student and unpublished ones to staff only. A student's
// download is the bytes the grader resolves for that student. A student
// cannot download from an assignment they cannot open, and someone outside
// the course reaches neither route. The dashboard links to the Data page,
// and the upload page links to the student's rows.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct StudentDataRoutesTests {

    private static let pool = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n6,B,119\n"

    private struct Fixture {
        let courseKey: String
        let setupID: String
        let assignment: APIAssignment
    }

    /// TEST101 with a published dataset `ward-cases` and an unpublished
    /// `draft-data`, and one open upload-mode assignment that attaches
    /// `ward-cases` as `lib.csv` with a 3-row course-scoped sample.
    private func fixture(on app: Application, courseID given: UUID? = nil, isOpen: Bool = true) async throws -> Fixture
    {
        let courseID: UUID
        if let given {
            courseID = given
        } else {
            courseID = try await app.testCourseID(enrollmentMode: .auto)
        }
        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
        let published = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(
                name: "Ward cases", slug: "ward-cases", description: "Admissions by ward",
                provenance: "Hospital extract", licence: "Course use only"),
            upload: .init(filename: "lib.csv", bytes: Data(Self.pool.utf8)), blobs: blobs, on: app.db
        ).dataset
        try await CourseDatasetService.setPublished(published, true, on: app.db)
        _ = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Draft data", slug: "draft-data"),
            upload: .init(filename: "draft.csv", bytes: Data(Self.pool.utf8)), blobs: blobs, on: app.db)

        let setupID = "sdr_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("lib.csv", Self.pool)])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null,\
            "submissionMode":"uploadOnly",\
            "datasets":[{"file":"lib.csv","kind":"rowSample","sampleSize":3,\
            "source":{"slug":"ward-cases","version":1},"scope":"course","transforms":[]}]}
            """
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: false, withZip: false)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Lab 2", isOpen: isOpen)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        return Fixture(courseKey: course.urlKey, setupID: setupID, assignment: assignment)
    }

    /// The course seed of `username` and the `lib.csv` the grader resolves
    /// for them.
    private func resolved(
        for username: String, fx: Fixture, on app: Application
    ) async throws -> (courseSeed: String, csv: String?) {
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
        let manifest = try #require(setup.decodedManifest())
        let seed = try await AssignmentSeedStore.ensureSeed(
            userID: try user.requireID(), assignmentID: try fx.assignment.requireID(), on: app.db)
        let courseSeed = try #require(
            try await CourseSeedStore.seedIfNeeded(
                manifest: manifest, userID: try user.requireID(), courseID: setup.courseID, on: app.db))
        let files = DatasetResolver.resolve(
            manifest: manifest, seedHex: seed, courseSeedHex: courseSeed,
            sourceDirectory: app.testSetupsDirectory + "shared/\(fx.setupID)/")
        return (courseSeed, files?["lib.csv"])
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.imATeapot, "")
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    // MARK: - The Data page

    @Test func aStudentSeesPublishedDatasetsAndTheirRowsLinks() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app)
            let (status, html) = try await get("/data/\(fx.courseKey)", cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(html.contains("Ward cases"))
            #expect(html.contains("Hospital extract"))
            #expect(html.contains("6 rows"))
            #expect(html.contains("/testsetups/\(fx.setupID)/data/lib.csv/mine.csv"))
            #expect(!html.contains("Draft data"))
        }
    }

    @Test func staffAlsoSeeUnpublishedDatasets() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let fx = try await fixture(on: app)
            let (status, html) = try await get("/data/\(fx.courseKey)", cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(html.contains("Draft data"))
            #expect(html.contains("Unpublished"))
        }
    }

    /// The TEST101 student asks for a course they are not enrolled in.
    @Test func someoneOutsideTheCourseReachesNeitherRoute() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let other = try await makeTestCourse(on: app, code: "SDRX", name: "Other").requireID()
            let fx = try await fixture(on: app, courseID: other)
            for path in ["/data/\(fx.courseKey)", "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv"] {
                let (status, _) = try await get(path, cookie: cookie, on: app)
                #expect(status == .forbidden || status == .notFound, "\(path) gave \(status)")
            }
        }
    }

    // MARK: - The download

    @Test func theDownloadIsTheBytesTheGraderResolvesForTheStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app)
            let (status, csv) = try await get(
                "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv", cookie: cookie, on: app)
            #expect(status == .ok)

            // The grader's call: the student's two seeds over the shared copy.
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
            let manifest = try #require(setup.decodedManifest())
            let seed = try await AssignmentSeedStore.ensureSeed(
                userID: try student.requireID(), assignmentID: try fx.assignment.requireID(), on: app.db)
            let courseSeed = try await CourseSeedStore.seedIfNeeded(
                manifest: manifest, userID: try student.requireID(), courseID: setup.courseID, on: app.db)
            #expect(courseSeed != nil)
            let graded = DatasetResolver.resolve(
                manifest: manifest, seedHex: seed, courseSeedHex: courseSeed,
                sourceDirectory: app.testSetupsDirectory + "shared/\(fx.setupID)/")
            #expect(csv == graded?["lib.csv"])
            // A 3-row sample under the header.
            #expect(csv.split(separator: "\n").count == 4)
        }
    }

    /// Each student's download is the resolver's output for that student's
    /// own seeds. Two students can draw the same 3 rows by chance, so the
    /// test compares each download with its own resolution, not the two
    /// downloads with each other.
    @Test func eachStudentDownloadsTheRowsResolvedForThem() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(on: app)
            var seeds: Set<String> = []
            for username in ["sdr_student_a", "sdr_student_b"] {
                let cookie = try await loginAsStudent(username, on: app)
                let (status, csv) = try await get(
                    "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv", cookie: cookie, on: app)
                #expect(status == .ok)
                let (courseSeed, graded) = try await resolved(for: username, fx: fx, on: app)
                seeds.insert(courseSeed)
                #expect(csv == graded)
            }
            #expect(seeds.count == 2)
        }
    }

    @Test func staffCanDownloadTheirOwnRows() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let fx = try await fixture(on: app, isOpen: false)
            let (status, csv) = try await get(
                "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv", cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(csv.split(separator: "\n").count == 4)
        }
    }

    /// A student who opened an assignment before it closed may still read
    /// its data, as they may still open its upload page.
    @Test func aStudentWhoOpenedAClosedAssignmentCanStillDownload() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app, isOpen: false)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            try await AssignmentParticipationStore.recordFirstAccess(
                userID: try student.requireID(), assignmentID: try fx.assignment.requireID(), on: app.db)

            let href = "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv"
            let (status, _) = try await get(href, cookie: cookie, on: app)
            #expect(status == .ok)
            let (_, html) = try await get("/data/\(fx.courseKey)", cookie: cookie, on: app)
            #expect(html.contains(href))
        }
    }

    /// An extension reopens a closed assignment for one student, so that
    /// student may read its data and the Data page lists the download.
    @Test func anExtensionOpensTheDataOfAClosedAssignment() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app, isOpen: false)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            try await APIAssignmentExtension(
                assignmentID: try fx.assignment.requireID(), userID: try student.requireID(),
                extendedDueAt: Date().addingTimeInterval(86_400)
            ).save(on: app.db)

            let href = "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv"
            let (status, _) = try await get(href, cookie: cookie, on: app)
            #expect(status == .ok)
            let (_, html) = try await get("/data/\(fx.courseKey)", cookie: cookie, on: app)
            #expect(html.contains(href))
        }
    }

    @Test func theDownloadIsAPrivateAttachment() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app)
            var headers = HTTPHeaders()
            try await app.asyncTest(
                .GET, "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in headers = res.headers })
            #expect(headers.first(name: .cacheControl) == "private, no-store")
            #expect(headers.first(name: .contentDisposition) == "attachment; filename=\"lib.csv\"")
            #expect(headers.first(name: .contentType)?.hasPrefix("text/csv") == true)
        }
    }

    @Test func aStudentCannotDownloadFromAnAssignmentTheyCannotOpen() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app, isOpen: false)
            let (status, _) = try await get(
                "/testsetups/\(fx.setupID)/data/lib.csv/mine.csv", cookie: cookie, on: app)
            #expect(status == .notFound)
        }
    }

    @Test func aFileThatIsNotADatasetIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app)
            let (status, _) = try await get(
                "/testsetups/\(fx.setupID)/data/notes.csv/mine.csv", cookie: cookie, on: app)
            #expect(status == .notFound)
        }
    }

    // MARK: - Links

    @Test func theDashboardAndTheUploadPageLinkToTheData() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            let fx = try await fixture(on: app)
            let (_, dashboard) = try await get("/", cookie: cookie, on: app)
            #expect(dashboard.contains("/data/\(fx.courseKey)"))

            let (status, submit) = try await get("/testsetups/\(fx.setupID)/submit", cookie: cookie, on: app)
            #expect(status == .ok)
            #expect(submit.contains("/testsetups/\(fx.setupID)/data/lib.csv/mine.csv"))
            #expect(submit.contains("3 rows"))
            #expect(submit.contains("/data/\(fx.courseKey)"))
        }
    }
}
