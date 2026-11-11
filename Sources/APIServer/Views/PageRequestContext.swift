// APIServer/Views/PageRequestContext.swift
//
// The request-scoped values every Elementary page needs, resolved once per
// request: the CSRF token, the app version, the idle-timeout settings and the
// static sprites.

import Core
import Vapor

/// Every view on a page holds one of these, and the page's view tree copies
/// it at each level. The values live in one shared, immutable `Storage`, so a
/// copy is one reference, not the 1 KB of the values themselves. A debug build
/// copies each view's fields through every nested builder closure, and with the
/// values inline the account page overflowed the 512 KB stack of a test thread
/// on macOS (docs/elementary-spike.md, "Keep view fields small").
struct PageRequestContext: Sendable {
    private final class Storage: Sendable {
        let currentUser: CurrentUserContext?
        let csrfToken: String
        let appVersion: String
        let sessionIdleTimeoutSeconds: Int
        let sessionIdleWarningSeconds: Int
        let iconSprite: String
        let mcpEnabled: Bool
        let avatarSprite: String

        init(
            currentUser: CurrentUserContext?, csrfToken: String, appVersion: String,
            sessionIdleTimeoutSeconds: Int, sessionIdleWarningSeconds: Int, iconSprite: String,
            mcpEnabled: Bool, avatarSprite: String
        ) {
            self.currentUser = currentUser
            self.csrfToken = csrfToken
            self.appVersion = appVersion
            self.sessionIdleTimeoutSeconds = sessionIdleTimeoutSeconds
            self.sessionIdleWarningSeconds = sessionIdleWarningSeconds
            self.iconSprite = iconSprite
            self.mcpEnabled = mcpEnabled
            self.avatarSprite = avatarSprite
        }
    }

    private let storage: Storage

    init(
        currentUser: CurrentUserContext?, csrfToken: String, appVersion: String,
        sessionIdleTimeoutSeconds: Int, sessionIdleWarningSeconds: Int, iconSprite: String,
        mcpEnabled: Bool = false, avatarSprite: String = ""
    ) {
        storage = Storage(
            currentUser: currentUser, csrfToken: csrfToken, appVersion: appVersion,
            sessionIdleTimeoutSeconds: sessionIdleTimeoutSeconds,
            sessionIdleWarningSeconds: sessionIdleWarningSeconds, iconSprite: iconSprite,
            mcpEnabled: mcpEnabled, avatarSprite: avatarSprite)
    }

    var currentUser: CurrentUserContext? { storage.currentUser }
    var csrfToken: String { storage.csrfToken }
    var appVersion: String { storage.appVersion }
    var sessionIdleTimeoutSeconds: Int { storage.sessionIdleTimeoutSeconds }
    var sessionIdleWarningSeconds: Int { storage.sessionIdleWarningSeconds }
    /// The inline icon sprite (`Resources/Sprites/icons.svg`), loaded once at startup.
    var iconSprite: String { storage.iconSprite }
    /// True when the content-authoring MCP endpoint is mounted. The admin tab
    /// bar shows its MCP item only then.
    var mcpEnabled: Bool { storage.mcpEnabled }
    /// The avatar sprite (`Resources/Sprites/avatar-sprite.svg`). `BaseLayout`
    /// renders it on every signed-in page, through `AvatarSprite`.
    var avatarSprite: String { storage.avatarSprite }

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
    /// The avatar parts, inlined by `BaseLayout` on every signed-in page and by
    /// the Present page.
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
        guard let svg = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return Self.inlineMarkup(svg)
    }

    /// The sprite as a page inlines it: every `<!-- … -->` comment, the
    /// whitespace between two tags and the whitespace at either end removed.
    /// That is about 14.6 KB of the 65 KB both sprites add to every
    /// signed-in page, which is sent uncompressed and uncached. Neither sprite
    /// has a text node, so the drawing is unchanged, and the favicon renderer
    /// trims and joins each symbol's lines, so its output is too. A byte scan
    /// rather than two `Regex` replacements: those took 15 ms, and a test app
    /// that never ran `loadSprites()` reads the sprites for every page.
    static func inlineMarkup(_ svg: String) -> String {
        let source = Array(svg.utf8)
        let (open, bang, dash, close) = (UInt8(ascii: "<"), UInt8(ascii: "!"), UInt8(ascii: "-"), UInt8(ascii: ">"))
        // A space, or a tab, line feed, vertical tab, form feed or return.
        let isSpace: (UInt8) -> Bool = { $0 == 0x20 || (0x09...0x0D).contains($0) }
        var kept: [UInt8] = []
        kept.reserveCapacity(source.count)
        var lastNonSpace: Int?  // in `kept`
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == open, index + 3 < source.count, source[index + 1] == bang, source[index + 2] == dash,
                source[index + 3] == dash
            {
                // `end` stops on the `-->` that closes it.
                var end = index + 4
                while end + 2 < source.count,
                    source[end] != dash || source[end + 1] != dash || source[end + 2] != close
                {
                    end += 1
                }
                // An unterminated comment is left as it is, with what follows.
                guard end + 2 < source.count else {
                    kept += source[index...]
                    break
                }
                index = end + 3
                continue
            }
            if byte == open, let last = lastNonSpace, kept[last] == close {
                // Only whitespace since the last tag closed: drop it.
                kept.removeSubrange((last + 1)...)
            }
            kept.append(byte)
            if !isSpace(byte) { lastNonSpace = kept.count - 1 }
            index += 1
        }
        let first = kept.firstIndex { !isSpace($0) } ?? kept.endIndex
        let last = kept.lastIndex { !isSpace($0) }.map { $0 + 1 } ?? first
        // Only whole comments and ASCII whitespace were cut, so the bytes are
        // still UTF-8; the file as read is the fallback all the same.
        return String(bytes: kept[first..<max(first, last)], encoding: .utf8) ?? svg
    }
}
