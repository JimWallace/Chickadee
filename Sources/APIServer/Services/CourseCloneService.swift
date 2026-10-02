// APIServer/Services/CourseCloneService.swift
//
// Clones a course into a new offering (docs/course-terms.md slice 4): the
// course's content and settings come along; its people, their work and its
// bindings to outside systems do not. The admin "Clone for new term" form and
// the older one-click admin copy both run this one path.
//
// Per assignment it delegates to `AssignmentAuthoringService.cloneAssignment`,
// the path the MCP `clone_assignment` tool and the instructor clone use, so
// the setup zip, starter notebook, reference solution, shared support files
// and first version snapshot are copied the same way everywhere.

import Core
import Fluent
import Foundation

/// The new offering a clone creates: its code, name and term.
struct CourseCloneTarget: Sendable {
    let code: String
    let name: String
    let term: AcademicTerm?
}

/// What a clone produces, for the caller's redirect and audit record.
struct CourseCloneResult: Sendable {
    let course: APICourse
    let assignmentCount: Int
}

enum CourseCloneService {
    /// Creates the course `target` names from `source`.
    ///
    /// Copied:
    /// - course sections, content items and their attachment files;
    /// - every assignment: setup, notebook, reference solution, support
    ///   files, section, order, and the per-assignment policies (secret
    ///   reveal, passing threshold, LMS sync exclusion);
    /// - the course settings: enrollment mode, slip-day policy, and the MCP
    ///   authoring guide.
    ///
    /// Not copied: enrollments, pre-enrollments, submissions, results, grade
    /// overrides, extensions, slip-day spends, achievement results, version
    /// history, and the LMS, BrightSpace and GitHub bindings. A new offering
    /// binds to its own LMS course.
    ///
    /// Every assignment starts closed and unvalidated, with NO due or start
    /// date and its solution hidden. The source's dates belong to the source's
    /// term, and a stale date is not harmless: with no date, or one in the
    /// past, an "after due" solution policy would show the answer key the
    /// moment the assignment opens. The instructor sets new dates, and
    /// re-enables the solution reveal, for the new term.
    ///
    /// The caller checks access and the code/term duplicate first; the unique
    /// index is the backstop.
    static func clone(
        source: APICourse,
        target: CourseCloneTarget,
        directories: AuthoringDirectories,
        contentFilesDirectory: String,
        on db: Database
    ) async throws -> CourseCloneResult {
        let sourceID = try source.requireID()
        let sections = try await APICourseSection.query(on: db)
            .filter(\.$courseID == sourceID)
            .sort(\.$sortOrder)
            .all()
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == sourceID)
            .sort(\.$sortOrder)
            .all()
        let setupsByID = Dictionary(
            try await APITestSetup.query(on: db)
                .filter(\.$courseID == sourceID)
                .all()
                .compactMap { setup in setup.id.map { ($0, setup) } },
            uniquingKeysWith: { first, _ in first })
        let contentItems = try await APICourseContentItem.query(on: db)
            .filter(\.$courseID == sourceID)
            .sort(\.$sortOrder)
            .all()

        let newCourse = APICourse(
            code: target.code, name: target.name, enrollmentMode: source.enrollmentMode, term: target.term)
        newCourse.slipDaysEnabled = source.slipDaysEnabled
        newCourse.slipDaysPerStudent = source.slipDaysPerStudent
        newCourse.slipDayExtensionHours = source.slipDayExtensionHours
        newCourse.slipDayReleaseRevealHold = source.slipDayReleaseRevealHold
        newCourse.mcpInstructions = source.mcpInstructions
        try await newCourse.save(on: db)
        let newCourseID = try newCourse.requireID()

        var sectionIDMap: [UUID: UUID] = [:]
        for section in sections {
            guard let oldID = section.id else { continue }
            let copy = APICourseSection(
                name: section.name, defaultGradingMode: section.defaultGradingMode,
                sortOrder: section.sortOrder, courseID: newCourseID)
            try await copy.save(on: db)
            sectionIDMap[oldID] = try copy.requireID()
        }

        var assignmentCount = 0
        // The caller runs the clone inside a transaction, so a failure at the
        // k-th copy rolls back the rows of the first k-1. Their files would
        // stay on disk; this removes them before the error leaves (#1743).
        var createdPaths: [String] = []
        do {
            for (index, assignment) in assignments.enumerated() {
                guard let setup = setupsByID[assignment.testSetupID] else { continue }
                let authored = try await AssignmentAuthoringService.cloneAssignment(
                    source: assignment, sourceSetup: setup, newTitle: assignment.title,
                    targetCourseID: newCourseID, directories: directories, on: db)
                createdPaths += authored.createdPaths
                let copy = authored.assignment
                // The three per-assignment policies came along in cloneAssignment.
                copy.sortOrder = assignment.sortOrder ?? index
                copy.sectionID = assignment.sectionID.flatMap { sectionIDMap[$0] }
                try await copy.save(on: db)
                assignmentCount += 1
            }

            for item in contentItems {
                if let copiedDirectory = try await copyContentItem(
                    item, toCourse: newCourseID,
                    sectionID: item.sectionID.flatMap { sectionIDMap[$0] },
                    contentFilesDirectory: contentFilesDirectory, on: db)
                {
                    createdPaths.append(copiedDirectory)
                }
            }
        } catch {
            let fm = FileManager.default
            for path in createdPaths { try? fm.removeItem(atPath: path) }
            throw error
        }

        return CourseCloneResult(course: newCourse, assignmentCount: assignmentCount)
    }

    /// Copies one content item and its attachment files. Attachments keep
    /// their ids: a file lives at `<itemID>/<attachmentID>`, so a copy under
    /// the new item id needs no rewrite of the metadata. Returns the copied
    /// attachment directory, or nil when the item has none to copy.
    private static func copyContentItem(
        _ item: APICourseContentItem, toCourse courseID: UUID, sectionID: UUID?,
        contentFilesDirectory: String, on db: Database
    ) async throws -> String? {
        let copy = APICourseContentItem(
            id: UUID(), courseID: courseID, sectionID: sectionID, sortOrder: item.sortOrder,
            title: item.title, kind: item.kind, itemDescription: item.itemDescription,
            links: item.links, attachments: item.attachments, updatedLabel: item.updatedLabel,
            isPublished: item.isPublished)
        let fm = FileManager.default
        var copiedDirectory: String?
        if let oldID = item.id, let newID = copy.id, !item.attachments.isEmpty {
            let sourceDir = contentFilesDirectory + oldID.uuidString
            if fm.fileExists(atPath: sourceDir) {
                try fm.createDirectory(atPath: contentFilesDirectory, withIntermediateDirectories: true)
                try fm.copyItem(atPath: sourceDir, toPath: contentFilesDirectory + newID.uuidString)
                copiedDirectory = contentFilesDirectory + newID.uuidString
            }
        }
        try await copy.save(on: db)
        return copiedDirectory
    }
}
