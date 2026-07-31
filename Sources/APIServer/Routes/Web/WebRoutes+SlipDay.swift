// APIServer/Routes/Web/WebRoutes+SlipDay.swift
//
// Student "spend a slip day" endpoints (#1228).
//
//   GET  /testsetups/:testSetupID/slip-day   → slip-day-confirm.leaf
//   POST /testsetups/:testSetupID/slip-day   → spend, redirect to /
//
// The GET is an explicit confirmation page — it names the assignment, the
// exact new deadline in local time, the cost against the remaining budget,
// and that the spend is not self-reversible — because a native confirm() is
// too thin for something with a fixed lifetime budget.  Both handlers resolve
// the full offer condition from scratch and refuse without writing anything
// when it does not hold (the dashboard action only renders when the offer is
// valid, so a refused request is a stale page or hand-crafted — mirroring the
// posture of WebRoutes+SecretReveal).  The balance-vs-concurrency race is the
// store's job: `SlipDayStore.spend` re-checks atomically.

import Core
import Fluent
import Vapor

/// Everything the confirm page and the spend POST need about one valid offer.
struct SlipDayOfferResolution {
    let assignment: APIAssignment
    let course: APICourse
    let policy: SlipDayPolicy
    let offer: SlipDayOffer
    /// The student's remaining course-wide balance (≥ 1 while an offer exists).
    let balance: Int
    /// Budget + per-student adjustment — the "of N" in "1 of N remaining".
    let totalBudget: Int
}

extension WebRoutes {

    // MARK: - GET /testsetups/:testSetupID/slip-day

    /// Renders the confirmation page when the offer currently holds; any
    /// refusal redirects to the dashboard, where the row's state explains
    /// itself (no offer icon, or the new deadline already granted).
    @Sendable
    func slipDayConfirmPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let resolution = try await resolveSlipDayOffer(req: req, user: user) else {
            return req.redirect(to: "/")
        }
        let fmt = waterlooDateTimeFormatter()
        let offer = resolution.offer
        let heldDeadline = resolution.assignment.dueAt.map { dueAt in
            offer.isStacked
                ? dueAt.addingTimeInterval(
                    TimeInterval(offer.spentOnAssignment * resolution.policy.extensionHours) * 3600)
                : dueAt
        }
        let context = SlipDayConfirmContext(
            currentUser: try await req.courseAwareUserContext(),
            testSetupID: resolution.assignment.testSetupID,
            assignmentTitle: resolution.assignment.title,
            courseCode: resolution.course.code,
            isStacked: offer.isStacked,
            heldDeadlineText: heldDeadline.map { fmt.string(from: $0) } ?? "—",
            newDeadlineText: fmt.string(from: offer.newDeadline),
            balance: resolution.balance,
            totalBudget: resolution.totalBudget,
            remainingAfter: resolution.balance - 1,
            extensionHours: resolution.policy.extensionHours,
            confirmLabel: offer.isStacked ? "Use another slip day" : "Use a slip day"
        )
        return try await req.view.render("slip-day-confirm", context)
            .encodeResponse(for: req)
    }

    // MARK: - POST /testsetups/:testSetupID/slip-day

    /// Performs the spend.  Re-resolves the whole offer condition (refusal
    /// redirects without writing), then delegates the race-sensitive part —
    /// balance and the staff-extension collision — to the store's atomic
    /// transaction.  A lost race lands in the `SlipDayError` catch and
    /// redirects silently: the dashboard shows the true outcome either way.
    @Sendable
    func spendSlipDay(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard let resolution = try await resolveSlipDayOffer(req: req, user: user) else {
            return req.redirect(to: "/")
        }

        let receipt: SlipDaySpendReceipt
        do {
            receipt = try await SlipDayStore.spend(
                userID: userID,
                assignment: resolution.assignment,
                policy: resolution.policy,
                on: req.db)
        } catch let error as SlipDayError {
            // The offer held a moment ago but the atomic re-check refused —
            // a concurrent double-submit or a just-granted staff extension.
            req.logger.info(
                "slip_day_spend_refused assignment=\(resolution.assignment.publicID) student=\(userID.uuidString) reason=\(String(describing: error))"
            )
            return req.redirect(to: "/")
        }

        await AuditLogger.record(
            action: .slipDaySpent,
            targetType: .assignment,
            targetID: resolution.assignment.id?.uuidString,
            metadata: [
                "assignment": resolution.assignment.publicID,
                "course_id": resolution.course.id?.uuidString ?? "",
                "extended_due_at": ISO8601DateFormatter().string(from: receipt.newDeadline),
                "stacked_count": String(receipt.spentOnAssignment),
            ],
            on: req)
        req.logger.info(
            "slip_day_spent assignment=\(resolution.assignment.publicID) student=\(userID.uuidString) stacked=\(receipt.spentOnAssignment) remaining=\(receipt.remainingBalance)"
        )
        return req.redirect(to: "/")
    }

    // MARK: - Offer resolution

    /// Resolves the full offer condition for the requested setup and the
    /// calling user.  Returns nil on every refusal: not enrolled staff-free,
    /// archived course, policy disabled, staff viewer, no published
    /// assignment, deadline not passed, staff extension present, no balance,
    /// or claim window closed.  Throws only for a missing setup (404) or a
    /// non-member of the course (the same cross-tenant guard as the submit
    /// form).
    private func resolveSlipDayOffer(
        req: Request, user: APIUser, now: Date = Date()
    ) async throws -> SlipDayOfferResolution? {
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        // Cross-tenant guard: only members of the setup's course may interact
        // with it (same gate as the submit form).
        try await requireCourseEnrollment(caller: user, courseID: setup.courseID, db: req.db)

        guard
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .first(),
            let assignmentID = assignment.id,
            let course = try await APICourse.find(assignment.courseID, on: req.db),
            !course.isArchived
        else {
            return nil
        }
        let policy = course.slipDayPolicy
        guard policy.enabled else { return nil }

        // Staff never spend slip days (their access doesn't depend on the
        // deadline), and students can't spend on a staff-only preview.
        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        guard !isStaff, assignment.visibility != .preview else { return nil }

        let enrollment = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == assignment.courseID)
            .first()
        guard let enrollment else { return nil }
        let adjustment = enrollment.slipDaysAdjustment ?? 0

        let spentInCourse = try await SlipDayStore.unrefundedCount(
            userID: userID, courseID: assignment.courseID, on: req.db)
        let spentOnAssignment = try await APISlipDaySpend.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID == assignmentID)
            .filter(\.$refundedAt == nil)
            .count()
        let extensionDueAt = try await studentExtensionDueAt(
            for: assignment, user: user, on: req.db)

        let totalBudget = policy.daysPerStudent + adjustment
        let balance = totalBudget - spentInCourse
        guard
            let offer = slipDayOffer(
                policy: policy,
                dueAt: assignment.dueAt,
                balance: balance,
                spentOnAssignment: spentOnAssignment,
                hasForeignExtension: extensionDueAt != nil && spentOnAssignment == 0,
                now: now)
        else { return nil }

        return SlipDayOfferResolution(
            assignment: assignment,
            course: course,
            policy: policy,
            offer: offer,
            balance: balance,
            totalBudget: totalBudget
        )
    }
}

// MARK: - View context

struct SlipDayConfirmContext: Encodable {
    let currentUser: CurrentUserContext?
    let testSetupID: String
    let assignmentTitle: String
    let courseCode: String
    /// True when this claim stacks on an existing slip-day extension.
    let isStacked: Bool
    /// The deadline the student currently holds: the original due date for a
    /// first claim, the current slip-day extension for a stacked one.
    let heldDeadlineText: String
    let newDeadlineText: String
    let balance: Int
    let totalBudget: Int
    let remainingAfter: Int
    let extensionHours: Int
    /// "Use a slip day" / "Use another slip day" — precomputed (LeafKit can't
    /// evaluate compound conditions reliably).
    let confirmLabel: String
}
