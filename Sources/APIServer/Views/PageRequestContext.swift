// APIServer/Views/PageRequestContext.swift
//
// The request-scoped values every Elementary page needs, resolved once per
// request. These are what the Leaf custom tags (`csrfToken`, `appVersion`,
// `sessionIdleTimeoutSeconds`, ...) read from the request at render time.

import CSRF
import Core
import Vapor

struct PageRequestContext: Sendable {
    let currentUser: CurrentUserContext?
    let csrfToken: String
    let appVersion: String
    let sessionIdleTimeoutSeconds: Int
    let sessionIdleWarningSeconds: Int
    /// The inline icon sprite (`_icons.leaf`), loaded once at startup.
    let iconSprite: String

    /// A static asset path with the cache-busting version query.
    func asset(_ path: String) -> String {
        "\(path)?v=\(appVersion)"
    }
}

extension PageRequestContext {
    init(request req: Request) {
        let security = req.application.securityConfiguration
        self.init(
            currentUser: req.currentUserContext,
            csrfToken: CSRF.createToken(from: req),
            appVersion: ChickadeeVersion.current,
            sessionIdleTimeoutSeconds: max(0, Int(security.sessionIdleTimeoutSeconds)),
            sessionIdleWarningSeconds: max(0, Int(security.sessionIdleWarningSeconds)),
            iconSprite: req.application.iconSprite
        )
    }
}

private struct IconSpriteStorageKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// The icon sprite markup. Read from disk when `loadIconSprite()` has not
    /// run (an app built without `AppMiddleware`, as the tests build one), so
    /// a page never loses its icons without a sound.
    var iconSprite: String {
        storage[IconSpriteStorageKey.self] ?? readIconSprite()
    }

    /// Caches the static icon sprite from the views directory. The file holds
    /// no Leaf tags, so its bytes are the rendered markup.
    func loadIconSprite() {
        storage[IconSpriteStorageKey.self] = readIconSprite()
    }

    private func readIconSprite() -> String {
        let path = directory.viewsDirectory + "_icons.leaf"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }
}
