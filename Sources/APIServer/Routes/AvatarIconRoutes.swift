// APIServer/Routes/AvatarIconRoutes.swift
//
// The browser tab icon (docs/student-avatars.md, "The tab icon").
//
//   GET /avatar-icon/:version/:key.svg  → one bird as SVG (`AvatarIconKey`)
//   GET /favicon.svg                    → the house bird, for bookmarks and crawlers
//
// Public: the key holds only what the leaderboard already shows, and no user
// id, so the route needs no session. A versioned URL never changes its bytes,
// so it is cached for a year.

import Foundation
import Vapor

struct AvatarIconRoutes: RouteCollection {
    /// A failure is a startup error in production (`loadAvatarIconRenderer`);
    /// a test app that serves no stylesheet gets a 500 here instead.
    let renderer: Result<AvatarIconRenderer, AvatarIconRendererError>
    let cache: AvatarIconCache

    /// The icon document needs nothing but its own inline style.
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'"

    init(
        renderer: Result<AvatarIconRenderer, AvatarIconRendererError>, cache: AvatarIconCache = AvatarIconCache()
    ) {
        self.renderer = renderer
        self.cache = cache
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get("avatar-icon", ":version", ":file", use: icon)
        routes.get("favicon.svg", use: houseIcon)
    }

    @Sendable
    func icon(req: Request) async throws -> Response {
        guard let file = req.parameters.get("file"), file.hasSuffix(".svg"),
            let version = req.parameters.get("version"), !version.isEmpty
        else { throw Abort(.notFound) }
        let key = String(file.dropLast(".svg".count))
        guard let svg = try svg(forKey: key) else { throw Abort(.notFound) }
        return response(svg, cacheControl: "public, max-age=31536000, immutable", on: req)
    }

    /// The URL has no version, so a day rather than a year: a release that
    /// changes the house bird reaches a bookmark the next day.
    @Sendable
    func houseIcon(req: Request) async throws -> Response {
        guard let svg = try svg(forKey: AvatarIconKey.house) else { throw Abort(.notFound) }
        return response(svg, cacheControl: "public, max-age=86400", on: req)
    }

    private func svg(forKey key: String) throws -> String? {
        if let cached = cache.svg(forKey: key) { return cached }
        guard let spec = AvatarIconKey.decode(key) else { return nil }
        let svg = try renderer.get().svg(for: spec)
        cache.insert(svg, forKey: key)
        return svg
    }

    private func response(_ svg: String, cacheControl: String, on req: Request) -> Response {
        SecurityHeadersMiddleware.setContentSecurityPolicy(Self.contentSecurityPolicy, on: req)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "image/svg+xml")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        headers.replaceOrAdd(name: .cacheControl, value: cacheControl)
        return Response(status: .ok, headers: headers, body: .init(string: svg))
    }
}

private struct AvatarIconRendererKey: StorageKey {
    typealias Value = Result<AvatarIconRenderer, AvatarIconRendererError>
}

extension Application {
    /// Builds the tab-icon renderer from the sprite and the stylesheet this app
    /// serves, once, and keeps it. `configure` calls it before the routes, so
    /// a missing symbol or token stops the server at boot.
    func loadAvatarIconRenderer() throws(AvatarIconRendererError) {
        let renderer = buildAvatarIconRenderer()
        storage[AvatarIconRendererKey.self] = renderer
        _ = try renderer.get()
    }

    /// The renderer `loadAvatarIconRenderer` built, or a new one when it has
    /// not run (an app built without `configure`, as the tests build one).
    func avatarIconRenderer() -> Result<AvatarIconRenderer, AvatarIconRendererError> {
        storage[AvatarIconRendererKey.self] ?? buildAvatarIconRenderer()
    }

    private func buildAvatarIconRenderer() -> Result<AvatarIconRenderer, AvatarIconRendererError> {
        let stylesheetPath = directory.publicDirectory + "styles.css"
        let stylesheet = (try? String(contentsOfFile: stylesheetPath, encoding: .utf8)) ?? ""
        return Result { () throws(AvatarIconRendererError) in
            try AvatarIconRenderer(sprite: sprite(.avatars), stylesheet: stylesheet)
        }
    }
}
