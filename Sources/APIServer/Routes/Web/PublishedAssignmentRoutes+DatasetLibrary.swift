// APIServer/Routes/Web/PublishedAssignmentRoutes+DatasetLibrary.swift
//
// The course dataset library in an assignment's Files panel
// (docs/datasets-course-library.md §4.5, slice 5b):
//
//   POST /instructor/:assignmentID/datasets/library/attach   {slug, filename?}
//   POST /instructor/:assignmentID/datasets/library/update   {file}
//   POST /instructor/:assignmentID/datasets/library/detach   {file, removeFile?}
//   POST /instructor/:assignmentID/datasets/library/scope    {file, courseScoped}
//   POST /instructor/:assignmentID/datasets/library/promote  {file}
//
// Each answers with the panel state (`DatasetsResponse`), as the datasets PUT
// does. `CourseDatasetService+Attachment.swift` does the work; these handlers
// own the access check and the steps after the edit. Attach, update, detach
// and a scope change alter the files in the zip or the rows each student
// receives, so they re-grade and re-validate. A promote keeps the bytes, the
// sample and the scope, so every student keeps the rows they had.

import Core
import Fluent
import Foundation
import SystemPackage
import Vapor

extension PublishedAssignmentRoutes {

    struct LibraryAttachBody: Content {
        var slug: String
        /// The filename in the setup zip. Nil means the version's filename.
        var filename: String?
    }

    struct LibraryFileBody: Content {
        var file: String
        /// Detach only: remove the file too.
        var removeFile: Bool?
    }

    /// The scope has its own body, so a request that leaves the value out is
    /// refused rather than read as `.assignment`.
    struct LibraryScopeBody: Content {
        var file: String
        /// True for the same rows in every assignment of the course.
        var courseScoped: Bool
    }

    // MARK: - Attach

    /// Attaches the newest version with course scope and no sample (decision
    /// 1 of the plan). The panel then sets the sample as for any dataset.
    @Sendable
    func attachLibraryDataset(req: Request) async throws -> DatasetsResponse {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryAttachBody.self)
        guard let dataset = try await CourseDatasetService.find(courseID: setup.courseID, slug: body.slug, on: req.db)
        else {
            throw AppError.notFound(resource: "Dataset")
        }
        try await libraryEdit {
            _ = try await CourseDatasetService.attach(
                dataset, to: setup,
                request: .init(filename: body.filename, scope: .course),
                testSetupsDirectory: req.application.testSetupsDirectory, on: req.db)
        }
        await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup, actingUserID: req.auth.get(APIUser.self)?.id,
            context: req)
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    // MARK: - Update to the newest version

    @Sendable
    func updateLibraryAttachment(req: Request) async throws -> DatasetsResponse {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryFileBody.self)
        try await libraryEdit {
            _ = try await CourseDatasetService.updateAttachment(
                file: body.file, in: setup, to: nil, testSetupsDirectory: req.application.testSetupsDirectory,
                on: req.db)
        }
        await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup, actingUserID: req.auth.get(APIUser.self)?.id,
            context: req)
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    // MARK: - Detach

    /// Ends the attachment. The file stays with its sample, unless
    /// `removeFile` asks for the file to go too.
    @Sendable
    func detachLibraryDataset(req: Request) async throws -> DatasetsResponse {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryFileBody.self)
        try await libraryEdit {
            try await CourseDatasetService.detach(
                file: body.file, from: setup, removeFile: body.removeFile ?? false,
                testSetupsDirectory: req.application.testSetupsDirectory, on: req.db)
        }
        // A course-scoped sample goes back to the assignment seed, so the rows
        // change even when the file stays.
        await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup, actingUserID: req.auth.get(APIUser.self)?.id,
            context: req)
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    // MARK: - Scope

    /// The scope decides which seed picks a student's rows, so a change
    /// re-grades and re-validates, as a detach does.
    @Sendable
    func setLibraryDatasetScope(req: Request) async throws -> DatasetsResponse {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryScopeBody.self)
        try await libraryEdit {
            _ = try await CourseDatasetService.setAttachmentScope(
                file: body.file, in: setup, to: body.courseScoped ? .course : .assignment, on: req.db)
        }
        await applyContentEditEffects(
            .gradeAffecting, assignment: assignment, setup: setup, actingUserID: req.auth.get(APIUser.self)?.id,
            context: req)
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    // MARK: - Promote

    /// Moves a CSV support file into the course library, named after the
    /// file. The instructor renames it on the Datasets tab. The new dataset
    /// starts unpublished (decision 3).
    @Sendable
    func promoteSupportFileToLibrary(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryFileBody.self)
        let name = FilePath(body.file).stem ?? body.file
        let slug = try await freeSlug(for: name, courseID: setup.courseID, on: req.db)
        try await libraryEdit {
            _ = try await CourseDatasetService.promote(
                file: body.file, from: setup, dataset: .init(name: name, slug: slug),
                testSetupsDirectory: req.application.testSetupsDirectory, on: req.db)
        }
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    /// A slug made from `name` that the course does not use yet: the plain
    /// slug, else the slug with "-2", "-3" and on. A name with no letter or
    /// digit gives "dataset". Two promotes that race can still pick the same
    /// slug, and the second is then refused as taken.
    private func freeSlug(for name: String, courseID: UUID, on db: any Database) async throws -> String {
        let made = CourseDatasetService.suggestedSlug(from: name)
        let base = made.isEmpty ? "dataset" : String(made.prefix(60))
        for suffix in [""] + (2...99).map({ "-\($0)" }) {
            let slug = base + suffix
            if try await CourseDatasetService.find(courseID: courseID, slug: slug, on: db) == nil { return slug }
        }
        return base
    }

    /// Runs one library operation and turns its refusal into a 400 that the
    /// panel shows beside the row.
    private func libraryEdit(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as CourseDatasetError {
            throw Abort(.badRequest, reason: error.description)
        }
    }
}
