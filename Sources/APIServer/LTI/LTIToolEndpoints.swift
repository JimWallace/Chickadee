// APIServer/LTI/LTIToolEndpoints.swift
//
// The tool URLs an LMS administrator enters when registering Chickadee
// (docs/lti-1-3.md). One place builds them, so the admin page and the launch
// routes cannot disagree about a path.

import Foundation

struct LTIToolEndpoints: Sendable, Equatable {
    static let loginPath = "/lti/login"
    static let launchPath = "/lti/launch"
    static let jwksPath = "/lti/jwks"

    /// `PUBLIC_BASE_URL` without a trailing slash, or nil when it is not set.
    let base: String?

    init(publicBaseURL: URL?) {
        guard var text = publicBaseURL?.absoluteString, !text.isEmpty else {
            base = nil
            return
        }
        while text.hasSuffix("/") { text.removeLast() }
        base = text
    }

    /// False when `PUBLIC_BASE_URL` is not set; the URLs are then paths only,
    /// which an LMS cannot use.
    var isAbsolute: Bool { base != nil }

    var loginURL: String { (base ?? "") + Self.loginPath }
    var launchURL: String { (base ?? "") + Self.launchPath }
    var jwksURL: String { (base ?? "") + Self.jwksPath }
}
