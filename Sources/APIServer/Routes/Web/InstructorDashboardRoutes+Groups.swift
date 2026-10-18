// APIServer/Routes/Web/InstructorDashboardRoutes+Groups.swift
//
// The instructor Groups tab: the active course's group set and its groups
// (docs/lab-groups.md, slice 1).
//
//   GET  /instructor/groups             → InstructorGroupsPage
//   POST /instructor/groups/sets        → make the course's group set
//   POST /instructor/groups/add         → add a group to a set
//   POST /instructor/groups/remove      → remove a group
//   POST /instructor/groups/import      → replace a set's memberships from a CSV file
//   POST /instructor/groups/membership  → put one student in a group (the Students tab)
//
// No route takes a path parameter. Each write names its set or group in the
// form and is authorized against that row's own course, at the instructor
// floor, in a course that is not archived: group membership is enrollment
// management. The `/instructor` gate admits course staff to read.

import Core
import Elementary
import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

extension InstructorDashboardRoutes {

    private struct CreateSetForm: Content {
        var name: String?
    }

    private struct AddGroupForm: Content {
        var setID: String?
        var name: String?
    }

    private struct RemoveGroupForm: Content {
        var groupID: String?
    }

    private struct ImportForm: Content {
        var setID: String?
        var file: File?
    }

    private struct MembershipForm: Content {
        var setID: String?
        var userID: String?
        /// The group's id, or "" for no group.
        var groupID: String?
    }

    /// The success messages a redirect may name. A code, not text, so a
    /// crafted link cannot put words in the banner.
    private enum GroupsNotice: String {
        case setCreated = "set"
        case groupAdded = "added"
        case groupRemoved = "removed"

        var text: String {
            switch self {
            case .setCreated: "Group set created."
            case .groupAdded: "Group added."
            case .groupRemoved: "Group removed. Its students are in no group."
            }
        }
    }

    /// The Groups tab routes, under the `/instructor` group.
    func registerGroupRoutes(on r: any RoutesBuilder) {
        r.get("groups", use: groupsPage)
        r.post("groups", "sets", use: createGroupSet)
        r.post("groups", "add", use: addGroup)
        r.post("groups", "remove", use: removeGroup)
        r.on(.POST, "groups", "import", body: .collect(maxSize: "2mb"), use: importGroups)
        r.post("groups", "membership", use: setGroupMembership)
    }

    // MARK: - Page

    @Sendable
    func groupsPage(req: Request) async throws -> Response {
        let notice = req.query[String.self, at: "notice"].flatMap(GroupsNotice.init(rawValue:))
        return try await renderGroupsPage(req: req, flash: FlashMessages(success: notice?.text))
    }

    /// The Groups tab for the active course, with `flash` above it. Every
    /// write that fails renders through here, so its message is the store's
    /// own sentence and never a query parameter.
    private func renderGroupsPage(req: Request, flash: FlashMessages) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        var course: APICourse?
        if let courseID = courseState.activeCourseUUID {
            course = try await APICourse.find(courseID, on: req.db)
        }
        let isArchived = course?.isArchived ?? false
        let isInstructor = user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let readOnlyNote: String? =
            if isArchived {
                "This course is archived and is read-only."
            } else if !isInstructor {
                "Only this course's instructors can change its groups."
            } else {
                nil
            }
        var panel: GroupSetPanel?
        if let courseID = course?.id, let set = try await CourseGroupStore.sets(courseID: courseID, on: req.db).first {
            panel = try await Self.groupSetPanel(for: set, courseID: courseID, on: req.db)
        }
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorGroupsPage(
                page: page, flash: flash, hasActiveCourse: course != nil, courseCode: course?.code ?? "",
                canEdit: readOnlyNote == nil, readOnlyNote: readOnlyNote, groupSet: panel)
        }.encodeResponse(for: req)
    }

    /// The set's groups, each with its enrolled students counted.
    static func groupSetPanel(
        for set: APICourseGroupSet, courseID: UUID, on db: any Database
    ) async throws -> GroupSetPanel {
        let setID = try set.requireID()
        let groups = try await CourseGroupStore.groups(inSet: setID, on: db)
        let students = try await CourseGroupStore.enrolledStudentIDs(courseID: courseID, on: db)
        let groupByUser = try await CourseGroupStore.groupIDsByUser(inSet: setID, on: db)
        var counts: [UUID: Int] = [:]
        for student in students {
            if let groupID = groupByUser[student] { counts[groupID, default: 0] += 1 }
        }
        let rows = groups.compactMap { group in
            group.id.map { GroupSetPanel.Row(id: $0.uuidString, name: group.name, memberCount: counts[$0] ?? 0) }
        }
        return GroupSetPanel(
            id: setID.uuidString, name: set.name, isManual: set.acceptsManualEdits, groups: rows,
            studentCount: students.count, ungroupedCount: students.count - counts.values.reduce(0, +))
    }

    // MARK: - Writes

    @Sendable
    func createGroupSet(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await req.requireActiveCourseID(for: user, action: "managing groups")
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .instructor, db: req.db)
        // Slice 1 shows one set per course, so a second is not made.
        if try await !CourseGroupStore.sets(courseID: courseID, on: req.db).isEmpty {
            return req.redirect(to: "/instructor/groups")
        }
        let form = try await req.decodeContent(CreateSetForm.self)
        do {
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: form.name ?? "", on: req.db)
            await Self.auditGroups(change: "set_created", title: set.name, courseID: courseID, on: req)
            return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.setCreated.rawValue)")
        } catch let error as CourseGroupError {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: error.description))
        }
    }

    @Sendable
    func addGroup(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(AddGroupForm.self)
        let set = try await requireWritableSet(form.setID, user: user, on: req)
        do {
            let group = try await CourseGroupStore.addGroup(named: form.name ?? "", to: set, on: req.db)
            await Self.auditGroups(change: "group_added", title: group.name, courseID: set.courseID, on: req)
            return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.groupAdded.rawValue)")
        } catch let error as CourseGroupError {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: error.description))
        }
    }

    @Sendable
    func removeGroup(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(RemoveGroupForm.self)
        guard let groupID = form.groupID.flatMap(UUID.init(uuidString:)),
            let group = try await APICourseGroup.find(groupID, on: req.db)
        else {
            throw AppError.notFound(resource: "Group")
        }
        let set = try await requireWritableSet(group.setID.uuidString, user: user, on: req)
        do {
            try await CourseGroupStore.removeGroup(group, of: set, on: req.db)
            await Self.auditGroups(change: "group_removed", title: group.name, courseID: set.courseID, on: req)
            return req.redirect(to: "/instructor/groups?notice=\(GroupsNotice.groupRemoved.rawValue)")
        } catch let error as CourseGroupError {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: error.description))
        }
    }

    @Sendable
    func importGroups(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(ImportForm.self)
        let set = try await requireWritableSet(form.setID, user: user, on: req)
        guard let file = form.file, file.data.readableBytes > 0 else {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: "Choose a CSV file to import."))
        }
        do {
            let parsed = try GroupRosterCSV.parse(Data(buffer: file.data))
            let result = try await CourseGroupStore.importRoster(parsed, into: set, on: req.db)
            await Self.auditGroups(
                change: "imported", title: set.name, courseID: set.courseID,
                extra: ["placed": String(result.placed), "unmatched": String(result.unmatched.count)], on: req)
            return try await renderGroupsPage(req: req, flash: Self.importFlash(result))
        } catch let error as CourseGroupError {
            return try await renderGroupsPage(req: req, flash: FlashMessages(error: error.description))
        }
    }

    @Sendable
    func setGroupMembership(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let form = try await req.decodeContent(MembershipForm.self)
        let set = try await requireWritableSet(form.setID, user: user, on: req)
        guard let userID = form.userID.flatMap(UUID.init(uuidString:)) else {
            throw WebAssignmentError.invalidParameter(name: "userID", reason: "Invalid user id.")
        }
        let raw = form.groupID ?? ""
        let groupID = raw.isEmpty ? nil : UUID(uuidString: raw)
        guard raw.isEmpty || groupID != nil else {
            throw WebAssignmentError.invalidParameter(name: "groupID", reason: "Invalid group id.")
        }
        do {
            try await CourseGroupStore.setMembership(userID: userID, groupID: groupID, in: set, on: req.db)
        } catch is CourseGroupError {
            return req.redirect(to: "/instructor/students?groupError=1")
        }
        await Self.auditGroups(
            change: "member_moved", title: set.name, courseID: set.courseID,
            extra: ["subject_user_id": userID.uuidString, "group_id": groupID?.uuidString ?? ""], on: req)
        return req.redirect(to: "/instructor/students")
    }

    /// Fills each student row's group from the course's group set. Returns
    /// false when the course has no set, so the roster shows no Group column.
    static func applyGroupColumn(
        to rows: inout [EnrolledStudentRow], courseID: UUID, on db: any Database
    ) async throws -> Bool {
        guard let set = try await CourseGroupStore.sets(courseID: courseID, on: db).first else { return false }
        let setID = try set.requireID()
        let groups = try await CourseGroupStore.groups(inSet: setID, on: db)
        let groupByUser = try await CourseGroupStore.groupIDsByUser(inSet: setID, on: db)
        let options = groups.compactMap { group in group.id.map { GroupOption(id: $0.uuidString, name: group.name) } }
        let nameByID = Dictionary(groups.compactMap { group in group.id.map { ($0, group.name) } }) { first, _ in first
        }
        for index in rows.indices where !rows[index].isPending && rows[index].role == CourseRole.student.rawValue {
            guard let userID = UUID(uuidString: rows[index].id) else { continue }
            let groupID = groupByUser[userID]
            rows[index].groupName = groupID.flatMap { nameByID[$0] }
            if set.acceptsManualEdits {
                rows[index].groupSelect = GroupSelectCell(
                    userID: rows[index].id, setID: setID.uuidString, personName: rows[index].displayName,
                    groupID: groupID?.uuidString ?? "", options: options)
            }
        }
        return true
    }

    // MARK: - Helpers

    /// The set named by `rawID`, after the caller is authorized to change its
    /// course: an instructor (or admin) of that course, and the course not
    /// archived.
    private func requireWritableSet(
        _ rawID: String?, user: APIUser, on req: Request
    ) async throws
        -> APICourseGroupSet
    {
        guard let setID = rawID.flatMap(UUID.init(uuidString:)),
            let set = try await APICourseGroupSet.find(setID, on: req.db)
        else {
            throw AppError.notFound(resource: "Group set")
        }
        try await requireCourseWriteAccess(caller: user, courseID: set.courseID, atLeast: .instructor, db: req.db)
        return set
    }

    private static func importFlash(_ result: CourseGroupStore.ImportResult) -> FlashMessages {
        var text = result.placed == 1 ? "Placed 1 student." : "Placed \(result.placed) students."
        if !result.groupsCreated.isEmpty {
            text += " Added \(result.groupsCreated.joined(separator: ", "))."
        }
        guard !result.unmatched.isEmpty else { return FlashMessages(success: text) }
        let shown = result.unmatched.prefix(10).joined(separator: ", ")
        let more = result.unmatched.count > 10 ? " and \(result.unmatched.count - 10) more" : ""
        return FlashMessages(
            success: text, notice: "No student of this course has these usernames: \(shown)\(more).")
    }

    private static func auditGroups(
        change: String, title: String, courseID: UUID, extra: [String: String] = [:], on req: Request
    ) async {
        var metadata = ["change": change, "title": title, "course_id": courseID.uuidString]
        metadata.merge(extra) { _, new in new }
        await AuditLogger.record(
            action: .enrollmentGroupsChanged, targetType: .course, targetID: courseID.uuidString,
            metadata: metadata, courseID: courseID, on: req)
    }
}
