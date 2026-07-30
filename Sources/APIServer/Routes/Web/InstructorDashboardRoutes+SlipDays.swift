// APIServer/Routes/Web/InstructorDashboardRoutes+SlipDays.swift
//
// Instructor Slip days panel (#1228): the active course's slip-day policy,
// the roster ledger (who spent what, with the resulting deadlines), and the
// staff levers — per-student budget adjustments and refunds.
//
//   GET  /instructor/slip-days           → instructor-slip-days.leaf
//   POST /instructor/slip-days/settings  → save policy (per-course instructor) → flash redirect
//   POST /instructor/slip-days/adjust    → ±1 a student's budget (TA+)        → flash redirect
//   POST /instructor/slip-days/refund    → refund one spend (TA+)             → flash redirect
//
// Role floors follow the convention in CourseAccessHelpers: the course-wide
// policy is course configuration (`.instructor`, like the MCP guide), while
// an adjustment or refund is an individual accommodation, sibling to the
// extension grant (`.ta`).  A refund recomputes or deletes the extension row
// through `SlipDayStore.refund`, so the student never keeps the extension
// for free.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    /// Bounds on the course policy form.  Wide enough for any real course
    /// (a 48 h chunky unit, a two-week outer window) while keeping obvious
    /// typos out of the schema.
    static let slipDayMaxPerStudent = 100
    static let slipDayMaxExtensionHours = 336

    // MARK: - GET /instructor/slip-days

    @Sendable
    func slipDaysPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        var course: APICourse?
        if let courseUUID = courseState.activeCourseUUID {
            course = try await APICourse.find(courseUUID, on: req.db)
        }
        let isArchived = course?.isArchived ?? false
        let holdsInstructorRole =
            user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let canEditSettings = holdsInstructorRole && !isArchived
        let canManageLedger = !isArchived

        let settingsReadOnlyNote: String?
        if canEditSettings {
            settingsReadOnlyNote = nil
        } else if isArchived {
            settingsReadOnlyNote = "This course is archived and is read-only."
        } else {
            settingsReadOnlyNote = "Only this course's instructors can change slip-day policy."
        }

        let policy = course?.slipDayPolicy
            ?? SlipDayPolicy.resolve(enabled: nil, daysPerStudent: nil, extensionHours: nil)
        var students: [SlipDayStudentRow] = []
        if let course, let courseUUID = course.id {
            students = try await Self.loadSlipDayStudentRows(
                courseUUID: courseUUID, policy: policy,
                canManageLedger: canManageLedger, db: req.db)
        }

        let ctx = InstructorSlipDaysContext(
            currentUser: try await req.courseAwareUserContext(),
            activeInstructorTab: "slip-days",
            hasActiveCourse: course != nil,
            courseCode: course?.code ?? "",
            enabled: policy.enabled,
            daysPerStudent: policy.daysPerStudent,
            extensionHours: policy.extensionHours,
            canEditSettings: canEditSettings,
            canManageLedger: canManageLedger,
            settingsReadOnlyNote: settingsReadOnlyNote,
            hasStudents: !students.isEmpty,
            students: students,
            flashSuccess: Self.slipDayFlashSuccess(req),
            flashError: Self.slipDayFlashError(req))
        return try await req.view.render("instructor-slip-days", ctx)
    }

    // MARK: - POST /instructor/slip-days/settings

    @Sendable
    func saveSlipDaySettings(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return req.redirect(to: "/instructor/slip-days?error=course")
        }
        // Course-wide policy → per-course instructor floor (admin bypass,
        // archived-course block), like the MCP guide.
        try await requireCourseWriteAccess(
            caller: user, courseID: courseUUID, atLeast: .instructor, db: req.db)

        struct SettingsForm: Content {
            /// "on" when the checkbox is ticked; absent otherwise.
            let enabled: String?
            let daysPerStudent: Int?
            let extensionHours: Int?
        }
        let form = try req.content.decode(SettingsForm.self)
        let enabled = form.enabled != nil
        let days = form.daysPerStudent ?? SlipDayPolicy.defaultDaysPerStudent
        let hours = form.extensionHours ?? SlipDayPolicy.defaultExtensionHours
        guard (0...Self.slipDayMaxPerStudent).contains(days),
            (1...Self.slipDayMaxExtensionHours).contains(hours)
        else {
            return req.redirect(to: "/instructor/slip-days?error=values")
        }

        course.slipDaysEnabled = enabled
        course.slipDaysPerStudent = days
        course.slipDayExtensionHours = hours
        try await course.save(on: req.db)

        await AuditLogger.record(
            action: .slipDaySettingsChanged,
            targetType: .course,
            targetID: courseUUID.uuidString,
            metadata: [
                "course_code": course.code,
                "course_id": courseUUID.uuidString,
                "enabled": String(enabled),
                "days_per_student": String(days),
                "extension_hours": String(hours),
            ],
            on: req)
        return req.redirect(to: "/instructor/slip-days?saved=settings")
    }

    // MARK: - POST /instructor/slip-days/adjust

    @Sendable
    func adjustSlipDayBudget(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return req.redirect(to: "/instructor/slip-days?error=course")
        }
        // A per-student budget adjustment is an individual accommodation,
        // sibling to the extension grant → `.ta` floor.
        try await requireCourseWriteAccess(
            caller: user, courseID: courseUUID, atLeast: .ta, db: req.db)

        struct AdjustForm: Content {
            let userID: String
            let delta: Int
        }
        let form = try req.content.decode(AdjustForm.self)
        guard let studentUUID = UUID(uuidString: form.userID), [-1, 1].contains(form.delta),
            let enrollment = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$userID == studentUUID)
                .filter(\.$course.$id == courseUUID)
                .first(),
            enrollment.role == .student,
            let student = try await APIUser.find(studentUUID, on: req.db)
        else {
            return req.redirect(to: "/instructor/slip-days?error=student")
        }

        let newAdjustment = (enrollment.slipDaysAdjustment ?? 0) + form.delta
        guard (-Self.slipDayMaxPerStudent...Self.slipDayMaxPerStudent).contains(newAdjustment)
        else {
            return req.redirect(to: "/instructor/slip-days?error=values")
        }
        enrollment.slipDaysAdjustment = newAdjustment
        try await enrollment.save(on: req.db)

        await AuditLogger.record(
            action: .slipDayAdjustmentChanged,
            targetType: .enrollment,
            targetID: enrollment.id?.uuidString,
            metadata: [
                "course_code": course.code,
                "course_id": courseUUID.uuidString,
                "student_username": student.username,
                "delta": String(form.delta),
                "adjustment": String(newAdjustment),
            ],
            on: req)
        return req.redirect(to: "/instructor/slip-days?saved=adjust")
    }

    // MARK: - POST /instructor/slip-days/refund

    @Sendable
    func refundSlipDaySpendAction(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return req.redirect(to: "/instructor/slip-days?error=course")
        }
        // A refund is an individual accommodation, sibling to the extension
        // revoke → `.ta` floor.
        try await requireCourseWriteAccess(
            caller: user, courseID: courseUUID, atLeast: .ta, db: req.db)

        struct RefundForm: Content {
            let spendID: String
        }
        let form = try req.content.decode(RefundForm.self)
        guard let spendUUID = UUID(uuidString: form.spendID) else {
            return req.redirect(to: "/instructor/slip-days?error=notfound")
        }

        let refunded: APISlipDaySpend
        do {
            refunded = try await SlipDayStore.refund(
                spendID: spendUUID,
                courseID: courseUUID,
                refundedBy: user.id,
                policy: course.slipDayPolicy,
                on: req.db)
        } catch SlipDayError.spendNotFound {
            return req.redirect(to: "/instructor/slip-days?error=notfound")
        } catch SlipDayError.alreadyRefunded {
            return req.redirect(to: "/instructor/slip-days?error=refunded")
        }

        let student = try await APIUser.find(refunded.userID, on: req.db)
        let assignment = try await APIAssignment.find(refunded.assignmentID, on: req.db)
        await AuditLogger.record(
            action: .slipDayRefunded,
            targetType: .assignment,
            targetID: refunded.assignmentID.uuidString,
            metadata: [
                "course_code": course.code,
                "course_id": courseUUID.uuidString,
                "student_username": student?.username ?? "",
                "assignment": assignment?.publicID ?? "",
            ],
            on: req)
        return req.redirect(to: "/instructor/slip-days?saved=refund")
    }

    // MARK: - Roster ledger assembly

    /// One row per student-role enrollment: balance figures plus the
    /// student's ledger entries (refunded ones included, for history).
    static func loadSlipDayStudentRows(
        courseUUID: UUID, policy: SlipDayPolicy, canManageLedger: Bool, db: any Database
    ) async throws -> [SlipDayStudentRow] {
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseUUID)
            .all()
        let studentEnrollments = enrollments.filter { $0.role == .student }
        guard !studentEnrollments.isEmpty else { return [] }

        // Same roster conventions as the Students tab: join in Swift and
        // leave the MCP service accounts out.
        let users = try await APIUser.query(on: db)
            .filter(\.$id ~~ studentEnrollments.map(\.userID))
            .filter(\.$role != UserRole.mcp.rawValue)
            .all()
        let userByID = Dictionary(
            users.compactMap { u in u.id.map { ($0, u) } },
            uniquingKeysWith: { first, _ in first })

        let ledger = try await SlipDayStore.courseLedger(courseID: courseUUID, on: db)
        var spendsByUserID: [UUID: [APISlipDaySpend]] = [:]
        for spend in ledger {
            spendsByUserID[spend.userID, default: []].append(spend)
        }

        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseUUID)
            .all()
        let titleByAssignmentID = Dictionary(
            assignments.compactMap { a in a.id.map { ($0, a.title) } },
            uniquingKeysWith: { first, _ in first })

        let fmt = waterlooDateTimeFormatter()
        var rows: [SlipDayStudentRow] = []
        for enrollment in studentEnrollments {
            guard let user = userByID[enrollment.userID] else { continue }
            let spends = spendsByUserID[enrollment.userID] ?? []
            let used = spends.filter { $0.refundedAt == nil }.count
            let adjustment = enrollment.slipDaysAdjustment ?? 0
            let total = policy.daysPerStudent + adjustment
            let spendRows = spends.map { spend in
                SlipDayLedgerSpendRow(
                    id: spend.id?.uuidString ?? "",
                    assignmentTitle: titleByAssignmentID[spend.assignmentID] ?? "(deleted)",
                    spentAtText: spend.spentAt.map { fmt.string(from: $0) } ?? "—",
                    extensionDueAtText: fmt.string(from: spend.extensionDueAt),
                    isRefunded: spend.refundedAt != nil,
                    refundedAtText: spend.refundedAt.map { fmt.string(from: $0) } ?? "",
                    canRefund: spend.refundedAt == nil && canManageLedger)
            }
            rows.append(
                SlipDayStudentRow(
                    userID: enrollment.userID.uuidString,
                    displayName: user.displayName ?? user.username,
                    username: user.username,
                    used: used,
                    remaining: total - used,
                    total: total,
                    adjustment: adjustment,
                    hasSpends: !spendRows.isEmpty,
                    spends: spendRows))
        }
        return rows.sorted {
            $0.username.localizedStandardCompare($1.username) == .orderedAscending
        }
    }

    // MARK: - Flash strings

    private static func slipDayFlashSuccess(_ req: Request) -> String? {
        switch req.query[String.self, at: "saved"] {
        case "settings":
            return "Slip-day settings saved."
        case "adjust":
            return "Student budget adjusted."
        case "refund":
            return "Slip day refunded. The student's extension was recomputed."
        default:
            return nil
        }
    }

    private static func slipDayFlashError(_ req: Request) -> String? {
        switch req.query[String.self, at: "error"] {
        case "course":
            return "No active course."
        case "values":
            return
                "Values out of range: days 0–\(slipDayMaxPerStudent), hours 1–\(slipDayMaxExtensionHours)."
        case "student":
            return "That student could not be found in this course."
        case "notfound":
            return "That slip-day spend could not be found."
        case "refunded":
            return "That slip day was already refunded."
        default:
            return nil
        }
    }
}

// MARK: - View contexts

/// One ledger entry under a student row on the Slip days tab.
struct SlipDayLedgerSpendRow: Encodable {
    let id: String
    let assignmentTitle: String
    let spentAtText: String
    /// The cumulative deadline this spend produced at the time it was made.
    let extensionDueAtText: String
    let isRefunded: Bool
    let refundedAtText: String
    /// Precomputed `!isRefunded && canManageLedger` (LeafKit can't evaluate
    /// compound conditions).
    let canRefund: Bool
}

/// One student-role enrollment on the Slip days roster ledger.
struct SlipDayStudentRow: Encodable {
    let userID: String
    let displayName: String
    let username: String
    let used: Int
    /// Budget + adjustment − used.  Can be negative after a claw-back; shown
    /// as-is to staff (it signals the over-claw-back).
    let remaining: Int
    let total: Int
    let adjustment: Int
    /// Precomputed `!spends.isEmpty` (Leaf's `array.isEmpty` is unreliable).
    let hasSpends: Bool
    let spends: [SlipDayLedgerSpendRow]
}

struct InstructorSlipDaysContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    let enabled: Bool
    let daysPerStudent: Int
    let extensionHours: Int
    /// Per-course instructor (or admin), non-archived — gates the policy form.
    let canEditSettings: Bool
    /// Non-archived — gates the ±1 and Refund buttons (TA floor is already
    /// guaranteed by the /instructor area middleware).
    let canManageLedger: Bool
    let settingsReadOnlyNote: String?
    /// Precomputed `!students.isEmpty` (Leaf's `array.isEmpty` is unreliable).
    let hasStudents: Bool
    let students: [SlipDayStudentRow]
    let flashSuccess: String?
    let flashError: String?
}
