// APIServer/Services/LectureNotebookService.swift
//
// Lecture notebooks (docs/lecture-notebooks.md): an ungraded content item
// whose notebook opens in the assignment editor. The item owns a backing
// `APITestSetup` that holds the notebook and the declared language. The setup
// never gets an `APIAssignment` row, and that absence is what keeps a lecture
// out of the gradebook, the LMS push, deadlines and validation.
//
// The web form (`CourseAdminRoutes+ContentItems`) and the MCP content tools
// both create and edit lecture notebooks through here, so the two surfaces
// cannot drift.

import Core
import Fluent
import Foundation

enum LectureNotebookService {

    // MARK: - Language

    /// True when `language` has an editor kernel, so a lecture notebook in it
    /// can open. Read from `LanguageDescriptor`, never from a list here.
    static func hasEditor(_ language: AssignmentLanguage) -> Bool {
        if case .notebookKernel = language.editorSupport { return true }
        return false
    }

    /// The declared language for `raw`. There is no default: a nil, blank or
    /// unknown value is refused, and so is a language with no editor kernel.
    static func parseLanguage(_ raw: String?) throws(CourseContentError) -> AssignmentLanguage {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw .lectureLanguageRequired(given: nil) }
        guard let language = AssignmentLanguage(rawValue: trimmed.lowercased()) else {
            throw .lectureLanguageRequired(given: trimmed)
        }
        guard hasEditor(language) else { throw .lectureLanguageHasNoEditor(language) }
        return language
    }

    /// The language that the lecture setup's manifest declares, or nil when it
    /// cannot be read.
    static func declaredLanguage(of setup: APITestSetup) -> AssignmentLanguage? {
        setup.decodedManifest().flatMap(AssignmentLanguage.resolve(manifest:))
    }

    // MARK: - Lookups

    /// The lecture-notebook item that owns `setupID`, or nil when the setup
    /// belongs to an assignment (or to nothing).
    static func item(forSetupID setupID: String, on db: any Database) async throws -> APICourseContentItem? {
        try await APICourseContentItem.query(on: db)
            .filter(\.$lectureTestSetupID == setupID)
            .first()
    }

    /// The ids of every lecture setup in `courseID`. The staff item list skips
    /// these setups: a setup with no assignment row would otherwise show as an
    /// unpublished draft.
    static func setupIDs(inCourse courseID: UUID, on db: any Database) async throws -> Set<String> {
        let items = try await APICourseContentItem.query(on: db)
            .filter(\.$courseID == courseID)
            .filter(\.$lectureTestSetupID != nil)
            .all()
        return Set(items.compactMap(\.lectureTestSetupID))
    }

    /// The backing setup of a lecture-notebook item.
    static func setup(of item: APICourseContentItem, on db: any Database) async throws -> APITestSetup? {
        guard let setupID = item.lectureTestSetupID else { return nil }
        return try await APITestSetup.find(setupID, on: db)
    }

    /// True when a student may open the lecture notebook: it is published,
    /// and a lecture notebook is never attached to an assignment.
    static func isVisibleToStudents(_ item: APICourseContentItem) -> Bool {
        item.isPublished && item.assignmentID == nil
    }

    // MARK: - Writes

    /// Creates a lecture notebook: the backing setup (an empty runner zip, a
    /// manifest with no suites that declares `language`, and the notebook),
    /// then the content item at the end of its section's lane. A nil
    /// `notebookData` seeds a blank notebook in the language. A failure
    /// removes the files it wrote.
    static func create(
        _ draft: ContentItemDraft,
        language: AssignmentLanguage,
        notebookData: Data?,
        in place: (courseID: UUID, sectionID: UUID?),
        setupsDirectory: String,
        on db: any Database
    ) async throws -> APICourseContentItem {
        let (courseID, sectionID) = place
        guard hasEditor(language) else { throw CourseContentError.lectureLanguageHasNoEditor(language) }
        let notebook = try notebookData ?? blankNotebook(title: draft.title, language: language)
        guard notebookCellCount(fromRaw: notebook) != nil else { throw CourseContentError.lectureNotebookInvalid }

        let made = try await makeSetup(
            manifest: emptyManifest, notebook: notebook, courseID: courseID, setupsDirectory: setupsDirectory,
            on: db)
        do {
            guard let setup = try await APITestSetup.find(made.setupID, on: db) else {
                throw CourseContentError.notALectureNotebook
            }
            try await mutateManifest(setup: setup, on: db) { props in
                applyLanguageDeclaration(language, to: &props)
            }
            let item = APICourseContentItem(
                courseID: courseID,
                sectionID: sectionID,
                sortOrder: try await nextSectionItemSortOrder(courseID: courseID, sectionID: sectionID, db: db),
                title: draft.title,
                kind: .notebook,
                itemDescription: draft.itemDescription,
                links: draft.links,
                updatedLabel: draft.updatedLabel,
                isPublished: draft.isPublished)
            item.lectureTestSetupID = made.setupID
            try await item.save(on: db)
            return item
        } catch {
            try? await deleteSetup(id: made.setupID, on: db)
            for path in made.createdPaths { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    /// Replaces the lecture's notebook. A student's working copy is never
    /// touched: they get the new version when they first open it, or when they
    /// reset their copy (docs/lecture-notebooks.md, "When the instructor edits
    /// the notebook mid-term").
    static func replaceNotebook(
        of item: APICourseContentItem, with data: Data, setupsDirectory: String, on db: any Database
    ) async throws {
        guard let setup = try await setup(of: item, on: db) else { throw CourseContentError.notALectureNotebook }
        guard notebookCellCount(fromRaw: data) != nil else { throw CourseContentError.lectureNotebookInvalid }
        try await AssignmentAuthoringService.writeAssignmentNotebook(
            setup: setup, notebookData: data, setupsDirectory: setupsDirectory, on: db)
    }

    /// Changes the declared language. The notebook is not rewritten: the
    /// editor normalizes its kernelspec onto the declared language on load.
    static func setLanguage(
        of item: APICourseContentItem, to language: AssignmentLanguage, on db: any Database
    ) async throws {
        guard hasEditor(language) else { throw CourseContentError.lectureLanguageHasNoEditor(language) }
        guard let setup = try await setup(of: item, on: db) else { throw CourseContentError.notALectureNotebook }
        try await mutateManifest(setup: setup, on: db) { props in
            applyLanguageDeclaration(language, to: &props)
        }
    }

    /// Deletes the backing setup row and its files. The item goes first (its
    /// foreign key would otherwise clear the column), so call this after the
    /// item is deleted. Student working copies stay on disk, as they do when
    /// an assignment is deleted.
    static func deleteSetup(id setupID: String, on db: any Database) async throws {
        guard let setup = try await APITestSetup.find(setupID, on: db) else { return }
        let paths = [setup.zipPath, setup.notebookPath].compactMap(\.self).filter { !$0.isEmpty }
        try await setup.delete(on: db)
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    /// Copies a lecture setup into `courseID` under a new id: its manifest,
    /// its notebook and a fresh empty runner zip. Returns the new setup's id
    /// and the files written, for the caller's cleanup if a later step fails.
    /// Course clone and bundle import use it.
    static func copySetup(
        _ source: APITestSetup, toCourse courseID: UUID, setupsDirectory: String, on db: any Database
    ) async throws -> (setupID: String, createdPaths: [String]) {
        let notebook = try await notebookData(for: source)
        return try await makeSetup(
            manifest: source.manifest, notebook: notebook, courseID: courseID, setupsDirectory: setupsDirectory,
            on: db)
    }

    /// Writes a lecture setup row with `manifest`, an empty runner zip and
    /// `notebook`. Returns the id and the files written.
    static func makeSetup(
        manifest: String, notebook: Data, courseID: UUID, setupsDirectory: String, on db: any Database
    ) async throws -> (setupID: String, createdPaths: [String]) {
        let setupID = freshShortID(prefix: "setup")
        let zipPath = setupsDirectory + "\(setupID).zip"
        _ = try await createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: nil, courseID: courseID)
        var created = [zipPath]
        do {
            try await setup.save(on: db)
            try await AssignmentAuthoringService.writeAssignmentNotebook(
                setup: setup, notebookData: notebook, setupsDirectory: setupsDirectory, on: db)
            if let path = setup.notebookPath { created.append(path) }
        } catch {
            for path in created { try? FileManager.default.removeItem(atPath: path) }
            // A write that failed after creating the file has not reached
            // `created` yet.
            if let path = setup.notebookPath, !created.contains(path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            throw error
        }
        return (setupID, created)
    }

    // MARK: - Private

    /// A manifest with no suites. Browser grading is what the manifest says,
    /// but nothing ever grades it: no assignment row exists, and
    /// `requireOpenStudentAssignment` refuses the `.submission` gate for a
    /// lecture setup.
    private static let emptyManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#

    /// A blank lecture notebook in `language`: a title cell and one empty
    /// code cell, with the language's kernelspec so the editor boots the
    /// right kernel. Not `defaultNotebookData`, whose cells are written for an
    /// assignment ("Write your assignment instructions here").
    static func blankNotebook(title: String, language: AssignmentLanguage) throws(CourseContentError) -> Data {
        guard case .notebookKernel(_, let kernelName, let kernelDisplayName, _, _) = language.editorSupport else {
            throw .lectureLanguageHasNoEditor(language)
        }
        let notebook: [String: Any] = [
            "cells": [
                ["cell_type": "markdown", "metadata": [String: Any](), "source": ["# \(title)\n"]],
                [
                    "cell_type": "code", "execution_count": NSNull(), "metadata": [String: Any](),
                    "outputs": [Any](), "source": [String](),
                ],
            ],
            "metadata": [
                "kernelspec": [
                    "display_name": kernelDisplayName, "language": language.rawValue, "name": kernelName,
                ],
                "language_info": ["name": language.rawValue],
            ],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: notebook, options: [.sortedKeys]) else {
            throw .lectureNotebookInvalid
        }
        return data
    }
}
