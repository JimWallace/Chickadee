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
// own the access check and the steps after the edit. Attach, update and
// detach change the bytes a student receives or the files in the zip, so
// they re-grade and re-validate. A scope change and a promote change neither
// the files nor the graded suite, as a datasets PUT does not.

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
        /// Scope only: true for the same rows in every assignment.
        var courseScoped: Bool?
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
            try await CourseDatasetService.attach(
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
            try await CourseDatasetService.updateAttachment(
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

    @Sendable
    func setLibraryDatasetScope(req: Request) async throws -> DatasetsResponse {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body = try await req.decodeContent(LibraryFileBody.self)
        let scope: DatasetSliceScope = body.courseScoped == true ? .course : .assignment
        try await libraryEdit {
            try await CourseDatasetService.setAttachmentScope(file: body.file, in: setup, to: scope, on: req.db)
        }
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
        try await libraryEdit {
            try await CourseDatasetService.promote(
                file: body.file, from: setup,
                dataset: .init(name: name, slug: CourseDatasetService.suggestedSlug(from: name)),
                testSetupsDirectory: req.application.testSetupsDirectory, on: req.db)
        }
        return try await datasetsPanelResponse(req: req, setup: setup)
    }

    /// Runs one library operation and turns its refusal into a 400 that the
    /// panel shows beside the row.
    private func libraryEdit<T>(_ operation: () async throws -> T) async throws {
        do {
            _ = try await operation()
        } catch let error as CourseDatasetError {
            throw Abort(.badRequest, reason: error.description)
        }
    }
}
