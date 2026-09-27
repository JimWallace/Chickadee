// APIServer/LTI/LTIDeepLinkRoutes.swift
//
// Deep Linking 2.0 (docs/lti-1-3.md "Deep Linking"): course staff choose
// Chickadee assignments from inside the LMS.
//
//   GET  /lti/deep-link → lti-deep-link.leaf, the bound course's assignments
//   POST /lti/deep-link → sign an LtiDeepLinkingResponse with the tool key and
//                         hand it to the platform's return URL
//
// Reached only after a verified deep-linking launch, which leaves the request
// in the session (`LTIPendingDeepLink`). Registered in the authenticated,
// CSRF-protected group. Each returned link launches `/lti/launch` with the
// assignment's public ID as a custom parameter.

import Core
import Fluent
import Vapor

struct LTIDeepLinkRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("lti", "deep-link", use: pickerPage)
        routes.post("lti", "deep-link", use: returnSelection)
    }

    struct Pending {
        let request: LTIPendingDeepLink
        let course: APICourse
        let platform: APILTIPlatform
    }

    @Sendable
    func pickerPage(req: Request) async throws -> View {
        let pending = try await Self.pending(req)
        return try await renderPicker(pending, error: nil, req: req)
    }

    @Sendable
    func returnSelection(req: Request) async throws -> View {
        struct Body: Content { var assignments: [String]? }
        let pending = try await Self.pending(req)
        let chosen = Set((try? req.content.decode(Body.self))?.assignments ?? [])
        let courseID = try pending.course.requireID()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .filter(\.$publicID ~~ Array(chosen))
            .sort(\.$title)
            .all()
        guard !assignments.isEmpty, assignments.count == chosen.count else {
            return try await renderPicker(pending, error: "Choose at least one assignment.", req: req)
        }
        guard pending.request.acceptMultiple || assignments.count == 1 else {
            return try await renderPicker(pending, error: "This LMS accepts one assignment at a time.", req: req)
        }

        let launchURL = LTIRoutes.endpoints(for: req).launchURL
        let response = LTIDeepLinkingResponse(
            clientID: pending.platform.clientID,
            platformIssuer: pending.platform.issuer,
            deploymentID: pending.request.deploymentID,
            data: pending.request.data,
            contentItems: assignments.map { assignment in
                LTIDeepLinkingResponse.ContentItem(
                    type: LTIDeepLinkingSettings.resourceLinkType, title: assignment.title, url: launchURL,
                    custom: [LTIPendingDeepLink.assignmentParameter: assignment.publicID])
            })
        let jwt = try await req.application.ltiToolKeyAuthority().sign(response)
        await AuditLogger.record(
            action: .ltiContentLinked, targetType: .course, targetID: courseID.uuidString,
            metadata: ["assignments": assignments.map(\.publicID).joined(separator: ",")],
            courseID: courseID, on: req)
        LTIPendingDeepLink.clear(from: req.session)

        // The form posts to the platform, another origin: allow exactly it.
        SecurityHeadersMiddleware.allowFormAction(
            SecurityHeadersMiddleware.cspOrigin(of: pending.request.returnURL), on: req)
        return try await req.view.render(
            "lti-deep-link-return",
            LTIDeepLinkReturnContext(
                currentUser: req.currentUserContext, returnURL: pending.request.returnURL, jwt: jwt))
    }

    private func renderPicker(_ pending: Pending, error: String?, req: Request) async throws -> View {
        let courseID = try pending.course.requireID()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$title)
            .all()
        return try await req.view.render(
            "lti-deep-link",
            LTIDeepLinkContext(
                currentUser: req.currentUserContext,
                courseCode: pending.course.code,
                acceptMultiple: pending.request.acceptMultiple,
                assignments: assignments.map { LTIDeepLinkOption(publicID: $0.publicID, title: $0.title) },
                error: error))
    }

    /// The request the launch left in the session, its course and platform,
    /// after checking the signed-in user is staff in that course.
    static func pending(_ req: Request) async throws -> Pending {
        guard
            let request = LTIPendingDeepLink.load(from: req.session),
            let courseID = req.session.data[LTIPendingDeepLink.courseKey].flatMap(UUID.init(uuidString:)),
            let course = try await APICourse.find(courseID, on: req.db),
            let platformID = course.ltiPlatformID,
            let platform = try await APILTIPlatform.find(platformID, on: req.db), platform.enabled
        else {
            throw Abort(.notFound, reason: "There is no LMS request to answer. Open the LMS content picker again.")
        }
        let user = try req.auth.require(APIUser.self)
        try await requireCourseRole(caller: user, courseID: courseID, atLeast: .ta, db: req.db)
        return Pending(request: request, course: course, platform: platform)
    }
}

struct LTIDeepLinkContext: Encodable {
    let currentUser: CurrentUserContext?
    let courseCode: String
    let acceptMultiple: Bool
    let assignments: [LTIDeepLinkOption]
    let error: String?
}

struct LTIDeepLinkOption: Encodable {
    let publicID: String
    let title: String
}

struct LTIDeepLinkReturnContext: Encodable {
    let currentUser: CurrentUserContext?
    let returnURL: String
    let jwt: String
}
