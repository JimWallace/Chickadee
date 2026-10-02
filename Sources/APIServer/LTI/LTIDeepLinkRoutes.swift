// APIServer/LTI/LTIDeepLinkRoutes.swift
//
// Deep Linking 2.0 (docs/lti-1-3.md "Deep Linking"): course staff choose
// Chickadee assignments from inside the LMS.
//
//   POST /lti/launch    → a verified deep-linking launch renders
//                         lti-deep-link.leaf, the bound course's assignments
//                         (`startPicker`)
//   POST /lti/deep-link → sign an LtiDeepLinkingResponse with the tool key and
//                         hand it to the platform's return URL
//
// The LMS shows the picker in a frame on its own page, where a browser does
// not send Chickadee's session cookie. So nothing here reads the session: the
// launch stores the request as an `APILTIDeepLinkRequest` under a random
// ticket, the picker form carries the ticket, and the choice consumes it
// once. The ticket also stands in for the CSRF token, which lives in the
// session too: it is unguessable, names one request, and dies when used. The
// route is therefore public and outside the CSRF group, like the launch.
//
// A launch from an LMS course that is not linked yet shows an instructor
// "Link this LMS course" first (`startBind`, lti-deep-link-bind.leaf). The
// request travels to `POST /lti/deep-link/bind` in a short-lived token the
// tool key signed (`LTIDeepLinkBindToken`); that route applies the same rules
// as `/lti/bind`, links the course, and continues to the picker.
//
// Every response may be framed by the platform's origins; every other page
// keeps `frame-ancestors 'self'`. Each returned link launches `/lti/launch`
// with the assignment's public ID as a custom parameter.

import Core
import Fluent
import Vapor

struct LTIDeepLinkRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("lti", "deep-link", use: returnSelection)
        routes.post("lti", "deep-link", "bind", use: bindSelection)
    }

    struct Pending {
        let ticket: String
        let row: APILTIDeepLinkRequest
        let course: APICourse
        let platform: APILTIPlatform
        let user: APIUser
    }

    /// The form the picker posts.
    struct SelectionBody: Content {
        var ticket: String?
        var assignments: [String]?
    }

    // MARK: - Start (from the launch)

    /// Stores the verified request under a new ticket and renders the picker.
    static func startPicker(
        _ request: LTIPendingDeepLink, course: APICourse, platform: APILTIPlatform, user: APIUser, req: Request
    ) async throws -> Response {
        let courseID = try course.requireID()
        let userID = try user.requireID()
        // The launch never changes an existing enrollment, so the LMS role
        // alone does not prove this account is staff in the course.
        try await requireCourseRole(caller: user, courseID: courseID, atLeast: .ta, db: req.db)
        let ticket = LTILaunchSecrets.randomToken()
        try await APILTIDeepLinkRequest(
            ticketHash: LTILaunchSecrets.hash(ticket), platformID: try platform.requireID(), courseID: courseID,
            userID: userID, request: request, expiresAt: Date().addingTimeInterval(APILTIDeepLinkRequest.lifetime)
        ).save(on: req.db)
        allowFraming(platform: platform, returnURL: request.returnURL, on: req)
        return try await renderPicker(
            ticket: ticket, course: course, acceptMultiple: request.acceptMultiple, error: nil, req: req
        ).encodeResponse(for: req)
    }

    // MARK: - Link the LMS course first

    /// Renders the course choice for an instructor's deep-linking launch from
    /// an LMS course that is not linked yet.
    static func startBind(
        _ request: LTIPendingDeepLink, platform: APILTIPlatform, contextID: String, contextTitle: String,
        user: APIUser, req: Request
    ) async throws -> Response {
        let token = LTIDeepLinkBindToken(
            userID: try user.requireID(), platformID: try platform.requireID(), contextID: contextID,
            contextTitle: contextTitle, request: request)
        allowFraming(platform: platform, returnURL: request.returnURL, on: req)
        return try await renderBind(
            token: try await req.application.ltiToolKeyAuthority().sign(token), contextTitle: contextTitle,
            user: user, error: nil, req: req
        ).encodeResponse(for: req)
    }

    // MARK: - POST /lti/deep-link/bind

    /// Links the LMS course to the chosen Chickadee course, then shows the
    /// picker. The rules are those of `/lti/bind`: a course the instructor
    /// teaches that is not linked yet, and an LMS course not linked to another.
    @Sendable
    func bindSelection(req: Request) async throws -> Response {
        struct Body: Content {
            var token: String?
            var courseID: String?
        }
        let body = try? req.content.decode(Body.self)
        guard let raw = body?.token,
            let token = try? await req.application.ltiToolKeyAuthority().verify(raw, as: LTIDeepLinkBindToken.self),
            let userID = token.userID,
            let user = try await APIUser.find(userID, on: req.db),
            let platform = try await APILTIPlatform.find(token.platformID, on: req.db), platform.enabled
        else { throw Self.requestGone }
        let request = token.request
        Self.allowFraming(platform: platform, returnURL: request.returnURL, on: req)

        // A second post of the same choice (a double click) finds the course
        // already linked and goes on to its picker, which checks the role.
        if let bound = try await APICourse.query(on: req.db)
            .filter(\.$ltiPlatformID == token.platformID)
            .filter(\.$ltiContextID == token.contextID)
            .first()
        {
            return try await Self.startPicker(request, course: bound, platform: platform, user: user, req: req)
        }
        guard let courseID = body?.courseID.flatMap(UUID.init(uuidString:)),
            let course = try await LTIBindRoutes.bindableCourses(for: user, on: req.db)
                .first(where: { $0.id == courseID })
        else {
            return try await Self.renderBind(
                token: raw, contextTitle: token.contextTitle, user: user,
                error: "Choose a course you teach that is not linked yet.", req: req
            ).encodeResponse(for: req)
        }
        try await LTICourseBinding.bind(course, platformID: token.platformID, contextID: token.contextID, on: req.db)
        await AuditLogger.record(
            action: .ltiCourseBound, targetType: .course, targetID: courseID.uuidString,
            metadata: ["course": course.code, "context_id": token.contextID], actorOverride: user,
            courseID: courseID, on: req)
        return try await Self.startPicker(request, course: course, platform: platform, user: user, req: req)
    }

    private static func renderBind(
        token: String, contextTitle: String, user: APIUser, error: String?, req: Request
    ) async throws -> View {
        try await req.view.render(
            "lti-deep-link-bind",
            LTIDeepLinkBindContext(
                currentUser: nil, embedded: true, token: token, contextTitle: contextTitle,
                courses: LTIBindRoutes.options(try await LTIBindRoutes.bindableCourses(for: user, on: req.db)),
                error: error))
    }

    // MARK: - POST /lti/deep-link

    @Sendable
    func returnSelection(req: Request) async throws -> View {
        let body = try? req.content.decode(SelectionBody.self)
        let pending = try await Self.pending(ticket: body?.ticket, req: req)
        let request = pending.row.request
        let chosen = Set(body?.assignments ?? [])
        let courseID = try pending.course.requireID()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .filter(\.$publicID ~~ Array(chosen))
            .sort(\.$title)
            .all()
        guard !assignments.isEmpty, assignments.count == chosen.count else {
            return try await Self.renderPicker(
                ticket: pending.ticket, course: pending.course, acceptMultiple: request.acceptMultiple,
                error: "Choose at least one assignment.", req: req)
        }
        guard request.acceptMultiple || assignments.count == 1 else {
            return try await Self.renderPicker(
                ticket: pending.ticket, course: pending.course, acceptMultiple: request.acceptMultiple,
                error: "This LMS accepts one assignment at a time.", req: req)
        }

        // Burn first, then sign: two concurrent posts of one ticket cannot
        // both get a response.
        guard
            try await SingleUseRecord.burn(
                on: req.db, table: APILTIDeepLinkRequest.schema, hashColumn: "ticket_hash",
                hash: pending.row.ticketHash)
        else { throw Self.requestGone }

        let launchURL = LTIRoutes.endpoints(for: req).launchURL
        let response = LTIDeepLinkingResponse(
            clientID: pending.platform.clientID,
            platformIssuer: pending.platform.issuer,
            deploymentID: request.deploymentID,
            data: request.data,
            contentItems: assignments.map { assignment in
                LTIDeepLinkingResponse.ContentItem(
                    type: LTIDeepLinkingSettings.resourceLinkType, title: assignment.title, url: launchURL,
                    custom: [LTIPendingDeepLink.assignmentParameter: assignment.publicID])
            })
        let jwt = try await req.application.ltiToolKeyAuthority().sign(response)
        await AuditLogger.record(
            action: .ltiContentLinked, targetType: .course, targetID: courseID.uuidString,
            metadata: ["assignments": assignments.map(\.publicID).joined(separator: ",")],
            actorOverride: pending.user, courseID: courseID, on: req)

        // The form posts to the platform, another origin: allow exactly it.
        SecurityHeadersMiddleware.allowFormAction(
            SecurityHeadersMiddleware.cspOrigin(of: request.returnURL), on: req)
        return try await req.view.render(
            "lti-deep-link-return",
            LTIDeepLinkReturnContext(currentUser: nil, embedded: true, returnURL: request.returnURL, jwt: jwt))
    }

    // MARK: - Helpers

    static let requestGone = Abort(
        .notFound, reason: "This LMS request has expired or was already answered. Open the LMS content picker again.")

    private static func renderPicker(
        ticket: String, course: APICourse, acceptMultiple: Bool, error: String?, req: Request
    ) async throws -> View {
        let courseID = try course.requireID()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$title)
            .all()
        return try await req.view.render(
            "lti-deep-link",
            LTIDeepLinkContext(
                currentUser: nil,
                embedded: true,
                ticket: ticket,
                courseCode: course.code,
                acceptMultiple: acceptMultiple,
                assignments: assignments.map { LTIDeepLinkOption(publicID: $0.publicID, title: $0.title) },
                error: error))
    }

    /// Lets the platform show these pages in its frame: its issuer origin and
    /// the origin of the return URL it signed.
    private static func allowFraming(platform: APILTIPlatform, returnURL: String, on req: Request) {
        SecurityHeadersMiddleware.allowFrameAncestors(
            [
                SecurityHeadersMiddleware.cspOrigin(of: platform.issuer),
                SecurityHeadersMiddleware.cspOrigin(of: returnURL),
            ],
            on: req)
    }

    /// The request the ticket names, after checking it is unanswered and
    /// unexpired, its platform is enabled, and its user is still staff in its
    /// course. Every failure is the same 404, so a guessed ticket learns
    /// nothing.
    static func pending(ticket: String?, req: Request) async throws -> Pending {
        guard let ticket, !ticket.isEmpty,
            let row = try await APILTIDeepLinkRequest.query(on: req.db)
                .filter(\.$ticketHash == LTILaunchSecrets.hash(ticket))
                .first(),
            !row.consumed, row.expiresAt > Date(),
            let course = try await APICourse.find(row.courseID, on: req.db),
            let platform = try await APILTIPlatform.find(row.platformID, on: req.db), platform.enabled,
            let user = try await APIUser.find(row.userID, on: req.db)
        else { throw requestGone }
        allowFraming(platform: platform, returnURL: row.returnURL, on: req)
        try await requireCourseRole(caller: user, courseID: row.courseID, atLeast: .ta, db: req.db)
        return Pending(ticket: ticket, row: row, course: course, platform: platform, user: user)
    }
}

/// Both page contexts set `embedded`: the pages render inside the LMS frame,
/// where the site nav's links (home, log in) would load pages that refuse to
/// be framed and that have no session there. `base.leaf` then omits the nav.
struct LTIDeepLinkContext: Encodable {
    let currentUser: CurrentUserContext?
    let embedded: Bool
    let ticket: String
    let courseCode: String
    let acceptMultiple: Bool
    let assignments: [LTIDeepLinkOption]
    let error: String?
}

struct LTIDeepLinkBindContext: Encodable {
    let currentUser: CurrentUserContext?
    let embedded: Bool
    let token: String
    let contextTitle: String
    let courses: [LTIBindCourseOption]
    let error: String?
}

struct LTIDeepLinkOption: Encodable {
    let publicID: String
    let title: String
}

struct LTIDeepLinkReturnContext: Encodable {
    let currentUser: CurrentUserContext?
    let embedded: Bool
    let returnURL: String
    let jwt: String
}
