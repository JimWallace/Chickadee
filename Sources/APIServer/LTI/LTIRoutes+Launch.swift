// APIServer/LTI/LTIRoutes+Launch.swift
//
// The LTI 1.3 launch (docs/lti-1-3.md "Launch"):
//
//   GET|POST /lti/login  — third-party initiated login. Finds the enabled
//                          registration, stores a single-use state and a
//                          nonce, sets a state cookie, and redirects to the
//                          platform's OIDC authorization endpoint.
//   POST     /lti/launch — the platform posts the signed id_token. The state
//                          is consumed atomically, the token is verified
//                          against the platform key set and every claim rule,
//                          and the user is signed in and sent to the course.
//
// Both are public and outside the CSRF group: the platform's signature and
// the single-use state are what authenticate them. The state cookie binds the
// launch to the browser that started the login, so an attacker cannot hand a
// victim a launch the attacker completed (login CSRF).

import Core
import Fluent
import Foundation
import Vapor

extension LTIRoutes {
    static let stateCookieName = "chickadee_lti_state"
    static let pendingPlatformKey = "lti_pending_platform"
    static let pendingContextKey = "lti_pending_context"
    static let pendingContextTitleKey = "lti_pending_context_title"

    /// The third-party login request, under the parameter names LTI 1.3 fixes.
    struct LoginParameters: Content {
        var iss: String?
        var loginHint: String?
        var targetLinkURI: String?
        var ltiMessageHint: String?
        var clientID: String?

        enum CodingKeys: String, CodingKey {
            case iss
            case loginHint = "login_hint"
            case targetLinkURI = "target_link_uri"
            case ltiMessageHint = "lti_message_hint"
            case clientID = "client_id"
        }
    }

    /// The platform's form post to the redirect URL.
    struct LaunchBody: Content {
        var idToken: String?
        var state: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case state, error
        }
    }

    // MARK: - GET|POST /lti/login

    @Sendable
    func login(req: Request) async throws -> Response {
        do {
            return try await performLogin(req)
        } catch let failure as LTILaunchFailure {
            req.logger.warning("LTI login refused: \(failure.logDetail)")
            throw failure
        }
    }

    private func performLogin(_ req: Request) async throws -> Response {
        let params =
            req.method == .POST
            ? try? req.content.decode(LoginParameters.self)
            : try? req.query.decode(LoginParameters.self)
        guard let params, let issuer = params.iss, let loginHint = params.loginHint, params.targetLinkURI != nil
        else { throw LTILaunchFailure.missingLoginParameters }

        var query = APILTIPlatform.query(on: req.db)
            .filter(\.$issuer == issuer)
            .filter(\.$enabled == true)
        if let clientID = params.clientID { query = query.filter(\.$clientID == clientID) }
        let matches = try await query.limit(2).all()
        guard let platform = matches.first else { throw LTILaunchFailure.unknownPlatform }
        guard matches.count == 1 else { throw LTILaunchFailure.ambiguousPlatform }

        let state = LTILaunchSecrets.randomToken()
        let nonce = LTILaunchSecrets.randomToken()
        try await APILTILoginState(
            stateHash: LTILaunchSecrets.hash(state), nonce: nonce, platformID: try platform.requireID(),
            expiresAt: Date().addingTimeInterval(APILTILoginState.lifetime)
        ).save(on: req.db)

        guard var redirect = URLComponents(string: platform.authLoginURL) else {
            throw LTILaunchFailure.unknownPlatform
        }
        var items = redirect.queryItems ?? []
        items += [
            URLQueryItem(name: "scope", value: "openid"),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "prompt", value: "none"),
            URLQueryItem(name: "client_id", value: platform.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.endpoints(for: req).launchURL),
            URLQueryItem(name: "login_hint", value: loginHint),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        if let hint = params.ltiMessageHint {
            items.append(URLQueryItem(name: "lti_message_hint", value: hint))
        }
        redirect.queryItems = items
        guard let location = redirect.string else { throw LTILaunchFailure.unknownPlatform }

        let response = req.redirect(to: location)
        response.cookies[Self.stateCookieName] = Self.stateCookie(state, req: req)
        return response
    }

    // MARK: - POST /lti/launch

    @Sendable
    func launch(req: Request) async throws -> Response {
        do {
            return try await performLaunch(req)
        } catch let failure as LTILaunchFailure {
            req.logger.warning("LTI launch refused: \(failure.logDetail)")
            throw failure
        }
    }

    private func performLaunch(_ req: Request) async throws -> Response {
        let body = try? req.content.decode(LaunchBody.self)
        if let error = body?.error { throw LTILaunchFailure.platformReportedError(error) }
        guard let state = body?.state, let idToken = body?.idToken else {
            throw LTILaunchFailure.missingLaunchParameters
        }
        guard let cookie = req.cookies[Self.stateCookieName]?.string, cookie == state else {
            throw LTILaunchFailure.stateCookieMissing
        }

        // Burn first, then read: two concurrent posts of one state cannot
        // both get past this line.
        let stateHash = LTILaunchSecrets.hash(state)
        guard
            try await MCPOAuthRoutes.burnConsumable(
                on: req.db, table: APILTILoginState.schema, hashColumn: "state_hash", hash: stateHash)
        else { throw LTILaunchFailure.stateUnknown }
        guard
            let login = try await APILTILoginState.query(on: req.db).filter(\.$stateHash == stateHash).first()
        else { throw LTILaunchFailure.stateUnknown }
        let now = Date()
        guard login.expiresAt > now else { throw LTILaunchFailure.stateExpired }

        guard let platform = try await APILTIPlatform.find(login.platformID, on: req.db), platform.enabled else {
            throw LTILaunchFailure.platformDisabled
        }
        let claims: LTILaunchClaims
        do {
            claims = try await req.application.ltiPlatformKeyCache.verify(
                idToken, platformID: login.platformID, jwksURL: platform.jwksURL, now: now)
        } catch {
            req.logger.warning("LTI id_token did not verify: \(error)")
            throw LTILaunchFailure.tokenInvalid
        }
        let launch: LTIValidatedLaunch
        do {
            launch = try LTILaunchValidator.validate(claims, against: platform.registration, now: now)
        } catch {
            throw LTILaunchFailure.claimRejected(error)
        }
        guard launch.nonce == login.nonce else { throw LTILaunchFailure.nonceMismatch }
        let deepLink = try launch.messageType == .deepLinking ? Self.deepLinkRequest(launch) : nil

        let resolution: LTIIdentityResolver.Resolution
        do {
            resolution = try await LTIIdentityResolver.resolve(
                launch: launch, platform: platform, authMode: req.application.authMode, on: req.db)
        } catch LTIIdentityResolver.Failure.linkRefused(let username) {
            // The username rides metadata, which the admin log buffer redacts.
            req.logger.warning(
                "LTI launch refused to link to an existing account", metadata: ["username": .string(username)])
            throw LTILaunchFailure.linkRefused
        }
        let user = resolution.user
        if resolution.created {
            await AuditLogger.record(
                action: .userProvisioned, targetType: .user, targetID: user.id?.uuidString,
                metadata: ["username": user.username, "provider": "lti", "platform": platform.displayName],
                actorUsernameOverride: "lti", on: req)
        }

        // Same session establishment as local and SSO sign-in.
        req.auth.login(user)
        req.session.rotateID()
        req.session.authenticate(user)
        await AuditLogger.record(
            action: .loginSuccess, targetType: .auth, targetID: user.id?.uuidString,
            metadata: ["username": user.username, "method": "lti"], actorOverride: user, on: req)

        // A deep link left over from an earlier launch must not steer this one.
        LTIPendingDeepLink.clear(from: req.session)
        deepLink?.save(to: req.session)
        let response = try await routeToCourse(
            launch: launch, platform: platform, user: user, isDeepLink: deepLink != nil, req: req)
        response.cookies[Self.stateCookieName] = Self.expiredStateCookie(req: req)
        return response
    }

    /// Sends the signed-in user to the bound course, enrolling them at the
    /// launch's role when they are not enrolled yet. An unbound context sends
    /// an instructor to the binding page and refuses anyone else.
    private func routeToCourse(
        launch: LTIValidatedLaunch, platform: APILTIPlatform, user: APIUser, isDeepLink: Bool, req: Request
    ) async throws -> Response {
        let platformID = try platform.requireID()
        guard let context = launch.context else { throw LTILaunchFailure.missingLaunchParameters }
        guard
            let course = try await LTICourseBinding.course(
                platformID: platformID, contextID: context.id, on: req.db)
        else {
            guard launch.courseRole == .instructor else { throw LTILaunchFailure.courseNotLinked }
            req.session.data[Self.pendingPlatformKey] = platformID.uuidString
            req.session.data[Self.pendingContextKey] = context.id
            req.session.data[Self.pendingContextTitleKey] = context.title ?? context.label ?? context.id
            return req.redirect(to: "/lti/bind")
        }
        let courseID = try course.requireID()
        let userID = try user.requireID()
        let enrolled =
            try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .first() != nil
        if !enrolled {
            try await APICourseEnrollment(userID: userID, courseID: courseID, role: launch.courseRole)
                .save(on: req.db)
        }
        try await Self.recordGradeService(launch: launch, course: course, userID: userID, on: req.db)
        req.session.data["activeCourseID"] = courseID.uuidString
        if isDeepLink {
            req.session.data[LTIPendingDeepLink.courseKey] = courseID.uuidString
            return req.redirect(to: "/lti/deep-link")
        }
        return req.redirect(to: try await Self.resourceLinkDestination(launch: launch, course: course, on: req.db))
    }

    /// Keeps the course's AGS line-items URL current from the launch, and,
    /// on a course that sends grades through AGS, queues again the pushes
    /// that waited for this student's first launch.
    static func recordGradeService(
        launch: LTIValidatedLaunch, course: APICourse, userID: UUID, on db: Database
    ) async throws {
        if let url = launch.agsEndpoint?.usableLineItemsURL,
            let secure = try? LTIPlatformForm.secureURL(url, field: .lineItemsURL),
            course.ltiLineItemsURL != secure
        {
            course.ltiLineItemsURL = secure
            try await course.save(on: db)
        }
        if course.usesLTIGrades, let courseID = course.id {
            try await LTIGradeSyncQueue.retryFailed(userID: userID, courseID: courseID, on: db)
        }
    }

    /// Where a resource-link launch lands: the assignment its `assignment`
    /// custom parameter names (set by deep linking) when that assignment is in
    /// the bound course, and the course dashboard otherwise.
    static func resourceLinkDestination(
        launch: LTIValidatedLaunch, course: APICourse, on db: Database
    ) async throws -> String {
        guard case .string(let publicID) = launch.custom[LTIPendingDeepLink.assignmentParameter],
            let courseID = course.id,
            let assignment = try await APIAssignment.query(on: db)
                .filter(\.$courseID == courseID)
                .filter(\.$publicID == publicID)
                .first()
        else { return "/" }
        return VanityURLRoutes.vanityPath(courseCode: course.code, assignmentSlug: assignment.slug)
    }

    /// The deep-linking request, checked before anyone is signed in: the
    /// platform must accept resource links and give a safe return URL, the
    /// launch must name a course, and only course staff may add content.
    static func deepLinkRequest(_ launch: LTIValidatedLaunch) throws -> LTIPendingDeepLink {
        guard let settings = launch.deepLinkingSettings, settings.acceptsResourceLinks,
            let returnURL = try? LTIPlatformForm.secureURL(settings.deepLinkReturnURL, field: .deepLinkReturnURL)
        else { throw LTILaunchFailure.deepLinkingUnsupported }
        guard launch.context != nil else { throw LTILaunchFailure.missingLaunchParameters }
        guard launch.courseRole >= .ta else { throw LTILaunchFailure.deepLinkingNotAllowed }
        return LTIPendingDeepLink(
            returnURL: returnURL, data: settings.data, deploymentID: launch.deploymentID,
            acceptMultiple: settings.acceptMultiple ?? false)
    }

    // MARK: - Helpers

    /// The tool URLs. `PUBLIC_BASE_URL` when set; otherwise the request's own
    /// host over http, which is enough for local testing and nothing else.
    static func endpoints(for req: Request) -> LTIToolEndpoints {
        let configured = req.application.appConfig.security.publicBaseURL
        let fallback = req.headers.first(name: .host).flatMap { URL(string: "http://\($0)") }
        return LTIToolEndpoints(publicBaseURL: configured ?? fallback)
    }

    /// The state cookie. `SameSite=None` over HTTPS, because the launch is a
    /// cross-site POST from the platform; a `Lax` cookie would not be sent.
    static func stateCookie(_ state: String, req: Request) -> HTTPCookies.Value {
        let secure = req.application.appConfig.security.sessionCookieSecure
        return HTTPCookies.Value(
            string: state, expires: nil, maxAge: Int(APILTILoginState.lifetime), domain: nil,
            path: "/lti", isSecure: secure, isHTTPOnly: true,
            sameSite: secure ? HTTPCookies.SameSitePolicy.none : .lax)
    }

    static func expiredStateCookie(req: Request) -> HTTPCookies.Value {
        var cookie = stateCookie("", req: req)
        cookie.maxAge = 0
        return cookie
    }
}
