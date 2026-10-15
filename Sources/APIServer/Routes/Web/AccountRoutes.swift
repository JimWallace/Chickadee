// APIServer/Routes/Web/AccountRoutes.swift
//
// User account & course membership routes (any authenticated user).
//
//   GET  /account                      → AccountPage (user info + enrolled courses)
//   POST /account/enroll               → join a course → redirect to /account
//   POST /account/unenroll/:courseID   → leave a course → redirect to /account
//   POST /account/avatar               → AccountRoutes+Avatar.swift
//   POST /account/avatar/hatch         → AccountRoutes+Avatar.swift
//   POST /account/avatar/restore       → AccountRoutes+Avatar.swift

import Core
import Elementary
import Fluent
import Vapor

struct AccountRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("account", use: accountPage)
        routes.post("account", "enroll", use: joinCourse)
        routes.post("account", "unenroll", ":courseID", use: leaveCourse)
        routes.post("account", "avatar", use: saveAvatar)
        routes.post("account", "avatar", "hatch", use: hatchAvatar)
        routes.post("account", "avatar", "restore", use: restoreAvatar)
    }

    // MARK: - GET /account

    @Sendable
    func accountPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        // All non-archived courses, newest term first (`courseListPrecedes`):
        // two offerings of one code must sort in a fixed order (#2231).
        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()
            .sorted(by: courseListPrecedes)

        // Current enrollments.
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()
        let enrolledIDs = Set(enrollments.compactMap(\.$course.id))

        // Slip-day balances per enrolled course (#1228): one query for every
        // unrefunded spend, grouped by course in memory.
        let unrefundedSpends = try await APISlipDaySpend.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$refundedAt == nil)
            .all()
        var spendCountByCourseID: [UUID: Int] = [:]
        for spend in unrefundedSpends {
            spendCountByCourseID[spend.courseID, default: 0] += 1
        }

        let spec = try await AvatarStore.ensureSpec(for: user, on: req.db)
        // Staff anywhere wear the staff ring here: this page belongs to no one
        // course (docs/student-wardrobe.md, "The staff ring"). One answer for
        // every bird on the page (#1758).
        let isStaff = try await AvatarStore.courseStaff(among: [userID], on: req.db).isEmpty == false
        // The bird's handle, drawn on first view, for a student in a current
        // course only: a pseudonym is for someone who appears pseudonymously,
        // and staff appear under their own name. `ensureHandle` is a read
        // once the bird has one.
        let isStudent = enrollments.contains { $0.role == .student && !$0.course.isArchived }
        // A current student's bird gets a handle on first need. Any other
        // bird shows the one it has, if any, so a hatch never changes a name
        // the card does not show.
        let handle = isStudent ? try await AvatarStore.ensureHandle(for: user, on: req.db) : user.avatarHandle

        let enrolledRows =
            enrollments
            .sorted { courseListPrecedes($0.course, $1.course) }
            .compactMap { e in
                e.course.id.map { id in
                    Self.enrolledCourseRow(
                        for: e, courseID: id, slipDaysUsed: spendCountByCourseID[id] ?? 0)
                }
            }

        let availableRows = allCourses.compactMap { c in
            Self.availableCourseRow(c, enrolledIDs: enrolledIDs)
        }

        // Personal-data export state (#557) for the "Your data" section.
        let export = try await APIDataExport.query(on: req.db)
            .filter(\.$userID == userID)
            .first()
        let dateFormatter = waterlooDateTimeFormatter()

        let github = try await accountGitHubContext(req: req, userID: userID)

        let avatarNotice = req.query[String.self, at: "avatar"]
        let avatarPicker = try await Self.avatarPickerContext(
            user: user, spec: spec, handle: handle, isStaff: isStaff, avatarNotice: avatarNotice, req: req)
        let identityName = accountIdentityName(
            displayName: user.displayName,
            preferredName: user.preferredName,
            username: user.username)
        let page = PageRequestContext(request: req)
        return try await HTMLResponse {
            AccountPage(
                page: page,
                flash: FlashMessages(
                    success: accountFlashSuccess(req: req, avatarNotice: avatarNotice),
                    error: avatarNotice == "nohatch"
                        ? "No hatches are left this term."
                        : req.query[String.self, at: "githubError"]
                            .flatMap(GitHubLinkError.init(rawValue:))?.message),
                username: user.username,
                preferredName: user.preferredName,
                identityName: identityName,
                identitySecondary: accountIdentitySecondary(
                    identityName: identityName, username: user.username),
                avatarPicker: avatarPicker,
                avatarInvalid: avatarNotice == "invalid",
                studentID: user.studentID,
                email: user.email,
                enrolledCourses: enrolledRows,
                availableCourses: availableRows,
                error: req.query[String.self, at: "error"],
                exportStatus: export?.statusValue?.rawValue ?? "none",
                exportRequestedAtDisplay: export.map { dateFormatter.string(from: $0.requestedAt) },
                exportCompletedAtDisplay: export?.completedAt.map(dateFormatter.string(from:)),
                exportCanRequest: dataExportCanBeRequested(export),
                exportNotice: req.query[String.self, at: "exportNotice"],
                exportError: req.query[String.self, at: "exportError"],
                showGitHub: github != nil,
                githubLogin: github?.login)
        }.encodeResponse(for: req)
    }

    /// The bird card, with its hatch control. `?hatch=confirm` asks for the
    /// hatch confirm, and `?avatar=hatched` for the new bird's strip.
    private static func avatarPickerContext(
        user: APIUser, spec: AvatarSpec, handle: String?, isStaff: Bool, avatarNotice: String?, req: Request
    ) async throws -> AvatarPickerContext {
        // Earned items are granted here, on the page that shows them, and
        // never while a result is written (docs/student-wardrobe.md, W3).
        // A failed grant falls back to what is stored, so an earned item is
        // never shown locked because of it.
        let userID = try user.requireID()
        let stored = (try? await WardrobeUnlockStore.unlocked(for: userID, on: req.db)) ?? []
        let unlocked = (try? await WardrobeUnlockStore.grantEarned(for: userID, on: req.db)) ?? stored
        // The life list is a cosmetic: a failed read hides it, not the page.
        let lifeList = (try? await AvatarStore.lifeList(for: user, on: req.db)) ?? []
        guard let term = AcademicTerm.current() else {
            return AvatarPickerContext(
                for: spec, isStaff: isStaff, handle: handle ?? "", unlocked: unlocked, lifeList: lifeList)
        }
        let status = try await AvatarStore.hatchStatus(for: user, term: term, on: req.db)
        let requested: AvatarHatchStrip? =
            avatarNotice == "hatched"
            ? .hatched : req.query[String.self, at: "hatch"] == "confirm" ? .confirm : nil
        let hatch = AvatarHatchContext(
            spec: spec, handle: handle, status: status, nextTerm: term.next, requested: requested,
            isStaff: isStaff)
        let formatter = waterlooDateTimeFormatter()
        formatter.timeStyle = .none
        let hatchedText = (status.lastHatchedAt ?? user.createdAt).map { "Hatched \(formatter.string(from: $0))" }
        return AvatarPickerContext(
            for: spec, isStaff: isStaff, handle: handle ?? "", hatchedText: hatchedText ?? "", hatch: hatch,
            unlocked: unlocked, lifeList: lifeList)
    }

    /// The one-shot success banner after a redirect back to this page.
    private func accountFlashSuccess(req: Request, avatarNotice: String?) -> String? {
        if avatarNotice == "saved" { return "Bird saved." }
        if avatarNotice == "restored" { return "Your previous bird is back." }
        return req.query[String.self, at: "github"]
            .flatMap(GitHubAccountLinkRoutes.Notice.init(rawValue:))?.message
    }

    /// The GitHub section, or nil when this user has no link to show and
    /// cannot make one. With no App registered, the page is unchanged; with an
    /// App but no `PUBLIC_BASE_URL`, students see nothing they cannot use (the
    /// admin GitHub page reports the missing base URL).
    private func accountGitHubContext(req: Request, userID: UUID) async throws -> AccountGitHubContext? {
        let link = try await APIGitHubAccountLink.query(on: req.db).filter(\.$userID == userID).first()
        let appRegistered = try await APIGitHubApp.query(on: req.db).first() != nil
        let canLink =
            appRegistered
            && GitHubUserAuthorization.redirectURI(
                publicBaseURL: req.application.securityConfiguration.publicBaseURL) != nil
        guard link != nil || canLink else { return nil }
        if canLink, link == nil {
            // The Link form posts here and the server redirects to github.com.
            // Chromium checks form-action across that redirect, against the CSP
            // of the page that holds the form.
            SecurityHeadersMiddleware.allowFormAction("https://github.com", on: req)
        }
        return AccountGitHubContext(login: link?.githubLogin)
    }

    // MARK: - POST /account/enroll

    @Sendable
    func joinCourse(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        struct JoinBody: Content { var courseID: String }
        let body = try await req.decodeContent(JoinBody.self)

        guard let courseID = UUID(uuidString: body.courseID),
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            return req.redirect(to: "/account?error=invalid")
        }

        try await ensureSeededEnrollment(userID: userID, courseID: courseID, on: req.db)

        return req.redirect(to: "/account")
    }

    // MARK: - POST /account/unenroll/:courseID

    @Sendable
    func leaveCourse(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString)
        else {
            throw Abort(.badRequest)
        }

        // Only open-mode courses can be self-left.
        // Closed courses are instructor-managed; auto courses are mandatory.
        guard let course = try await APICourse.find(courseID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard course.enrollmentMode == .open else {
            throw AppError.forbidden(action: "leave a \(course.enrollmentMode.rawValue)-enrolment course")
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .delete()

        // If the session active course was this one, clear it so next request re-selects.
        if req.session.data["activeCourseID"] == idString {
            req.session.data["activeCourseID"] = nil
        }

        return req.redirect(to: "/account")
    }
}

// MARK: - View context types

/// The name shown beside the identity circle: the full name the IdP released
/// when there is one, else the preferred name, else the username.
///
/// One resolution, used for the heading and for the identity row, so the two
/// can never disagree.
func accountIdentityName(displayName: String?, preferredName: String?, username: String) -> String {
    for candidate in [displayName, preferredName] {
        if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
            return candidate
        }
    }
    return username
}

/// The muted line under the identity name, or nil when it would merely repeat
/// it. A local account with no name on file resolves its heading to the
/// username, and printing the username twice reads as a bug rather than as
/// identity.
func accountIdentitySecondary(identityName: String, username: String) -> String? {
    identityName == username ? nil : username
}

/// The account page's GitHub section.
private struct AccountGitHubContext {
    /// The linked login, or nil when no account is linked. The section is
    /// built without a login only when the Link button works.
    let login: String?
}
