// APIServer/Routes/Web/StudentDataRoutes.swift
//
// What students see of the course dataset library
// (docs/datasets-course-library.md §4.6):
//
//   GET /data/:courseKey                              → CourseDataPage
//   GET /testsetups/:testSetupID/data/:filename/mine.csv → the viewer's own rows
//
// The Data page lives at `/data/:courseKey`, not `/:courseKey/data`: a fixed
// second segment would route ahead of the vanity URL `/:courseCode/:slug`
// and hide an assignment whose slug is "data".
//
// Both routes need an enrollment in the course. A student sees published
// datasets only, and only the assignments they may read (`mayRead`); staff
// see both in full. The download serves the bytes the grader gives the viewer
// (`StudentDatasetDelivery`), so it is never the pool unless every student
// receives the whole file (decision 2).

import Core
import Elementary
import Fluent
import Foundation
import Vapor

struct StudentDataRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("data", ":courseKey", use: courseDataPage)
        routes.get("testsetups", ":testSetupID", "data", ":filename", "mine.csv", use: myDatasetRows)
    }

    // MARK: - GET /data/:courseKey

    @Sendable
    func courseDataPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let key = req.parameters.get("courseKey"),
            let course = try await findActiveCourse(byKey: key, viewer: user.id, on: req.db),
            let courseID = course.id
        else {
            throw AppError.notFound(resource: "Course")
        }
        try await req.cachedRequireCourseEnrollment(caller: user, courseID: courseID)
        let isStaff = try await req.cachedIsCourseStaff(user, inCourse: courseID)
        guard let userID = user.id else { throw AppError.notFound(resource: "Course") }

        let datasets = try await CourseDatasetService.list(courseID: courseID, on: req.db)
            .filter { isStaff || $0.isPublished }
        let newest = try await CourseDatasetService.newestVersions(of: datasets, on: req.db)
        let downloads = try await Self.downloadsBySlug(
            courseID: courseID, user: user, userID: userID, isStaff: isStaff, req: req)
        let entries = try datasets.map { dataset in
            let version = newest[try dataset.requireID()]
            return CourseDataEntry(
                name: dataset.name, description: dataset.datasetDescription, provenance: dataset.provenance,
                licence: dataset.licence, isPublished: dataset.isPublished,
                rowsText: version.map { InstructorDatasetDetail.rowsText($0.rowCount) } ?? "",
                columns: version?.columns ?? [], downloads: downloads[dataset.slug] ?? [])
        }
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            CourseDataPage(page: page, courseCode: course.code, datasets: entries)
        }.encodeResponse(for: req)
    }

    /// For each dataset slug, a download for every assignment the viewer may
    /// read that attaches it, by assignment title.
    private static func downloadsBySlug(
        courseID: UUID, user: APIUser, userID: UUID, isStaff: Bool, req: Request
    ) async throws -> [String: [CourseDataEntry.Download]] {
        let setups = try await APITestSetup.query(on: req.db).filter(\.$courseID == courseID).all()
        let assignments = try await APIAssignment.query(on: req.db).filter(\.$courseID == courseID).all()
        let bySetup = Dictionary(assignments.map { ($0.testSetupID, $0) }, uniquingKeysWith: { first, _ in first })
        var downloads: [String: [CourseDataEntry.Download]] = [:]
        for setup in setups {
            let specs = setup.decodedManifest()?.datasets ?? []
            guard let setupID = setup.id, let assignment = bySetup[setupID], !specs.isEmpty,
                try await mayRead(assignment, user: user, userID: userID, isStaff: isStaff, req: req)
            else { continue }
            for spec in specs {
                guard let slug = spec.source?.slug else { continue }
                downloads[slug, default: []].append(
                    .init(
                        assignmentTitle: assignment.title, filename: spec.file,
                        href: CourseDataEntry.downloadHref(setupID: setupID, filename: spec.file)))
            }
        }
        return downloads.mapValues { $0.sorted { $0.assignmentTitle < $1.assignmentTitle } }
    }

    /// Whether the viewer may read the data of `assignment`: the rule of
    /// `closedAssignmentGate`, without its first-access record. Staff always
    /// may; a student when the assignment is open for them (an extension
    /// counts) or `studentMayViewClosedAssignment` admits them. The upload
    /// page is behind that gate, so its links to the student's rows never
    /// lead to a 404.
    private static func mayRead(
        _ assignment: APIAssignment, user: APIUser, userID: UUID, isStaff: Bool, req: Request
    ) async throws -> Bool {
        if isStaff { return true }
        if try await isAssignmentEffectivelyOpen(assignment, for: user, req: req) { return true }
        return try await studentMayViewClosedAssignment(assignment, userID: userID, on: req.db)
    }

    // MARK: - GET /testsetups/:testSetupID/data/:filename/mine.csv

    @Sendable
    func myDatasetRows(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let filename = req.parameters.get("filename"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            let userID = user.id
        else {
            throw AppError.notFound(resource: "Dataset")
        }
        try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
        guard let assignment = try await assignmentByTestSetupID(setupID, on: req.db) else {
            throw AppError.notFound(resource: "Dataset")
        }
        let isStaff = try await req.cachedIsCourseStaff(user, inCourse: setup.courseID)
        guard try await Self.mayRead(assignment, user: user, userID: userID, isStaff: isStaff, req: req),
            let csv = try await StudentDatasetDelivery.file(
                named: filename, setup: setup, assignment: assignment, userID: userID,
                testSetupsDirectory: req.application.testSetupsDirectory, on: req.db)
        else {
            throw AppError.notFound(resource: "Dataset")
        }
        let response = Response(status: .ok, body: .init(string: csv))
        response.headers.replaceOrAdd(name: .contentType, value: "text/csv; charset=utf-8")
        // The filename is a bare name from the manifest; a quote in it would
        // end the header value early.
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
        response.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"\(safeName)\"")
        // The rows are this student's own; no shared cache may keep them.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }
}
