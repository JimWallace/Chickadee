// APIServer/Routes/Web/InstructorDashboardRoutes+GroupSource.swift
//
// Where the Groups tab's groups come from (docs/lab-groups.md, slice 6b): an
// instructor reads them from the LEARN Sections of the course, syncs them now,
// or stops the sync and edits them here.
//
//   POST /instructor/groups/source  → `source` = learnSections or manual
//   POST /instructor/groups/sync    → read the groups from LEARN now
//
// Both write the active course's group set, at the instructor floor, in a
// course that is not archived, as the other Groups writes do.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    private struct SourceForm: Content {
        var source: String?
    }

    /// True when the course can read its groups from LEARN: the deployment
    /// has BrightSpace credentials and the course is linked to an org unit.
    static func learnLinked(_ course: APICourse, on application: Application) -> Bool {
        application.brightSpaceAppCredentials != nil && !(course.brightspaceOrgUnitID ?? "").isEmpty
    }

    @Sendable
    func setGroupSource(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let course = try await requireWritableCourse(user: user, on: req)
        let courseID = try course.requireID()
        switch try await req.decodeContent(SourceForm.self).source {
        case CourseGroupSource.learnSections.rawValue:
            guard Self.learnLinked(course, on: req.application) else {
                return try await renderGroupsPage(
                    req: req, flash: FlashMessages(error: "Link this course to LEARN on the LEARN tab first."))
            }
            // A failed first read puts the set back as it was, so the groups
            // stay editable and the error is true.
            let previous = try await CourseGroupStore.sets(courseID: courseID, on: req.db).first
            let restore = previous.map { (source: $0.sourceRaw, externalID: $0.externalID) }
            let set = try await CourseGroupStore.setSource(.learnSections, courseID: courseID, on: req.db)
            if let problem = try await syncFromLearn(set, course: course, req: req) {
                if let restore {
                    set.sourceRaw = restore.source
                    set.externalID = restore.externalID
                    try await set.save(on: req.db)
                } else {
                    try await set.delete(on: req.db)
                }
                return try await renderGroupsPage(req: req, flash: FlashMessages(error: problem))
            }
            await Self.auditGroups(change: "source_learn_sections", title: set.name, courseID: courseID, on: req)
            return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.learnSynced.rawValue)")
        case CourseGroupSource.manual.rawValue:
            let set = try await CourseGroupStore.setSource(.manual, courseID: courseID, on: req.db)
            await Self.auditGroups(change: "source_manual", title: set.name, courseID: courseID, on: req)
            return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.learnStopped.rawValue)")
        default:
            throw WebAssignmentError.invalidParameter(name: "source", reason: "Unknown group source.")
        }
    }

    @Sendable
    func syncGroupsFromLearn(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let course = try await requireWritableCourse(user: user, on: req)
        guard let set = try await CourseGroupStore.sets(courseID: try course.requireID(), on: req.db).first,
            set.source == .learnSections || set.source == .learnGroups
        else {
            return try await renderGroupsPage(
                req: req,
                flash: FlashMessages(error: "These groups are not read from LEARN, so there is nothing to sync."))
        }
        if let problem = try await syncFromLearn(set, course: course, req: req) {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: problem))
        }
        return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.learnSynced.rawValue)")
    }

    /// The active course, when the user may change its groups.
    private func requireWritableCourse(user: APIUser, on req: Request) async throws -> APICourse {
        let courseID = try await req.requireActiveCourseID(for: user, action: "managing groups")
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
        guard let course = try await APICourse.find(courseID, on: req.db) else {
            throw AppError.notFound(resource: "Course")
        }
        return course
    }

    /// Reads the set from LEARN now, as the ten-minute sweep does. Returns
    /// nil when it did, else the reason it did not, for the error banner. A
    /// sync that fails changes nothing: its writes are one transaction.
    private func syncFromLearn(_ set: APICourseGroupSet, course: APICourse, req: Request) async throws -> String? {
        guard let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty,
            let client = try await req.application.brightSpaceClient(forCourse: course)
        else {
            return "LEARN is not connected for this course, so its groups cannot be read. See the LEARN tab."
        }
        let result: CourseGroupStore.SyncResult?
        do {
            result = try await syncLearnGroupSet(
                set, orgUnitID: orgUnitID, client: client, on: req.db, application: req.application)
        } catch {
            req.logger.warning("LEARN group sync from the Groups tab failed: \(error)")
            return "The groups could not be read from LEARN. Try again later."
        }
        guard let result else {
            return "LEARN listed no groups or no students for this course, so nothing changed."
        }
        await Self.auditGroups(
            change: "learn_synced", title: set.name, courseID: set.courseID,
            extra: ["placed": String(result.placed)], on: req)
        return nil
    }
}
