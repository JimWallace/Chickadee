// APIServer/Views/PageRequestContext.swift
//
// The request-scoped values every Elementary page needs, resolved once per
// request: the CSRF token, the app version, the idle-timeout settings and the
// static sprites.

import Core
import Vapor

struct PageRequestContext: Sendable {
    let currentUser: CurrentUserContext?
    let csrfToken: String
    let appVersion: String
    let sessionIdleTimeoutSeconds: Int
    let sessionIdleWarningSeconds: Int
    /// The inline icon sprite (`Resources/Sprites/icons.svg`), loaded once at startup.
    let iconSprite: String
    /// True when the content-authoring MCP endpoint is mounted. The admin tab
    /// bar shows its MCP item only then.
    var mcpEnabled = false
    /// The avatar sprite (`Resources/Sprites/avatar-sprite.svg`). Only pages that show an
    /// avatar render it, through `AvatarSprite`.
    var avatarSprite = ""

    /// A static asset path with the cache-busting version query.
    func asset(_ path: String) -> String {
        "\(path)?v=\(appVersion)"
    }
}

extension PageRequestContext {
    init(request req: Request) {
        self.init(request: req, csrfToken: CSRFMiddleware.createToken(from: req))
    }

    /// The context for a page that shows the course tabs. The course-aware
    /// user is resolved and cached on the request first, so `currentUser`
    /// carries the enrolled courses. A route behind
    /// `NavCourseContextMiddleware` already has it cached.
    static func courseAware(_ req: Request) async throws -> PageRequestContext {
        _ = try await req.courseAwareUserContext()
        return PageRequestContext(request: req)
    }

    /// The error page's context. An error can be thrown before
    /// SessionsMiddleware has run, and reading the session then traps in a
    /// debug build, so the token is minted only when a session exists. With
    /// no session there is no signed-in user, so no form on the page needs one.
    init(errorPageRequest req: Request) {
        self.init(request: req, csrfToken: req.hasSession ? CSRFMiddleware.createToken(from: req) : "")
    }

    private init(request req: Request, csrfToken: String) {
        let security = req.application.securityConfiguration
        self.init(
            currentUser: req.currentUserContext,
            csrfToken: csrfToken,
            appVersion: ChickadeeVersion.current,
            sessionIdleTimeoutSeconds: max(0, Int(security.sessionIdleTimeoutSeconds)),
            sessionIdleWarningSeconds: max(0, Int(security.sessionIdleWarningSeconds)),
            iconSprite: req.application.iconSprite,
            mcpEnabled: req.application.appConfig.mcp.mode.isMounted,
            avatarSprite: req.application.sprite(.avatars)
        )
    }
}

private struct SpriteStorageKey: StorageKey {
    typealias Value = [StaticSprite: String]
}

/// A static SVG sprite in `Resources/Sprites/`. Its bytes are the rendered
/// markup.
enum StaticSprite: String, CaseIterable, Sendable {
    /// The Feather icons, inlined on every page by the layout.
    case icons = "icons.svg"
    /// The avatar parts, inlined once by each page that shows an avatar.
    case avatars = "avatar-sprite.svg"
}

extension Application {
    /// The markup of `sprite`. Read from disk when `loadSprites()` has not run
    /// (an app built without `AppMiddleware`, as the tests build one), so a
    /// page never loses its icons without a sound.
    func sprite(_ sprite: StaticSprite) -> String {
        storage[SpriteStorageKey.self]?[sprite] ?? readSprite(sprite)
    }

    var iconSprite: String { sprite(.icons) }

    /// Caches every static sprite once, at startup.
    func loadSprites() {
        storage[SpriteStorageKey.self] = Dictionary(
            uniqueKeysWithValues: StaticSprite.allCases.map { ($0, readSprite($0)) })
    }

    private func readSprite(_ sprite: StaticSprite) -> String {
        let path = directory.resourcesDirectory + "Sprites/" + sprite.rawValue
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
