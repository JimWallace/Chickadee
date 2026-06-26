// APIServer/Middleware/SupportedBrowserMatrix.swift
//
// Chickadee's simplified browser-support matrix, modeled on D2L Brightspace's
// browser-support policy (https://community.d2l.com/brightspace/kb/articles/5663-browser-support).
// D2L "supports" the latest versions of Chrome / Edge / Firefox / Safari, shows a
// "your browser is looking a little retro" notice below that, and "blocks" only
// extreme / insecure cases. We collapse that to TWO tiers — `.supported` and
// `.unsupported` — and we deliberately NEVER block: an unsupported browser gets a
// non-blocking warning and degrades to server-side grading (the
// BrowserResultRoutes failover) plus the .ipynb upload path, so it can still
// submit and never records a silent 0. (Equity/AODA: don't lock a student out of
// a deadline because of their browser.)
//
// The version FLOORS below are the single source of truth, seeded from the
// UWaterloo LEARN / D2L baseline (≈ the latest stable as of Sept 2025). Bump them
// here as the supported line moves; nothing else needs to change.
//
// Detection is deliberately CONSERVATIVE: we return `.unsupported` ONLY when we
// can confidently identify a known engine AND parse a major version below its
// floor. An unrecognized or unparseable UA returns `.unknown` (no warning) — the
// runtime capability probe + grading failover are the real safety net, so a fuzzy
// UA must never nag a student who is in fact fine.

import Vapor

/// Where a browser falls relative to Chickadee's supported matrix.
enum BrowserSupportTier: String, Sendable {
    /// A known engine at or above its version floor.
    case supported
    /// A known engine below its version floor → warn + degrade (never block).
    case unsupported
    /// A UA we can't confidently classify → show no warning; the runtime
    /// capability probe + grading failover decide.
    case unknown
}

/// The result of assessing a User-Agent against the matrix, carrying enough
/// detail to render the warning copy and a telemetry breadcrumb.
struct BrowserSupportAssessment: Sendable, Equatable {
    let tier: BrowserSupportTier
    /// Matched engine display name ("Chrome", "Edge", "Firefox", "Safari"); nil when unknown.
    let engine: String?
    /// Parsed major version; nil when unparseable / unknown.
    let majorVersion: Int?
    /// The version floor this engine is held to; nil when unknown.
    let minimumSupported: Int?
}

enum SupportedBrowserMatrix {

    // MARK: - The matrix (single source of truth)

    /// Minimum supported MAJOR version per engine. Seeded from the UWaterloo LEARN
    /// / D2L baseline (latest stable ≈ Sept 2025). Bump as the supported line moves.
    static let minimumChrome = 140  // Chrome / Chromium (Blink), incl. Android
    static let minimumEdge = 140  // Edge (Blink)
    static let minimumFirefox = 143  // Firefox (Gecko), incl. Android
    static let minimumSafari = 26  // Safari / WebKit (desktop + iOS; Apple year-versioning)

    // MARK: - Assessment

    /// Assess a raw User-Agent string against the matrix.
    static func assess(userAgent: String?) -> BrowserSupportAssessment {
        guard let ua = userAgent, !ua.isEmpty else {
            return BrowserSupportAssessment(
                tier: .unknown, engine: nil, majorVersion: nil, minimumSupported: nil)
        }

        // iOS / iPadOS first: every browser there is WKWebView (WebKit), so the
        // OS / Safari version governs capability regardless of the branded name
        // (CriOS / FxiOS / EdgiOS). Mirrors EditorBrowserEngine.isWebKit's
        // iOS-first ordering.
        if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") {
            let version = majorVersion(after: "Version/", in: ua) ?? majorVersion(after: "OS ", in: ua)
            return classify(engine: "Safari", version: version, floor: minimumSafari)
        }

        // Desktop / Android. Order matters: Edge and Chrome UAs both carry
        // "Chrome/", and Chrome / Edge UAs carry "Safari/", so check the most
        // specific token first.
        if ua.contains("Edg/") {
            return classify(engine: "Edge", version: majorVersion(after: "Edg/", in: ua), floor: minimumEdge)
        }
        if ua.contains("Firefox/") {
            return classify(
                engine: "Firefox", version: majorVersion(after: "Firefox/", in: ua), floor: minimumFirefox)
        }
        if ua.contains("Chrome/") {  // also matches HeadlessChrome/ (Blink) — fine
            return classify(engine: "Chrome", version: majorVersion(after: "Chrome/", in: ua), floor: minimumChrome)
        }
        if ua.contains("Safari/") && ua.contains("Version/") {
            return classify(engine: "Safari", version: majorVersion(after: "Version/", in: ua), floor: minimumSafari)
        }

        return BrowserSupportAssessment(
            tier: .unknown, engine: nil, majorVersion: nil, minimumSupported: nil)
    }

    /// Assess the request's `User-Agent` header.
    static func assess(_ request: Request) -> BrowserSupportAssessment {
        assess(userAgent: request.headers.first(name: "User-Agent"))
    }

    /// True only for a confidently-identified, below-floor browser.
    static func isUnsupported(userAgent: String?) -> Bool {
        assess(userAgent: userAgent).tier == .unsupported
    }

    // MARK: - Helpers

    private static func classify(engine: String, version: Int?, floor: Int) -> BrowserSupportAssessment {
        guard let version else {
            // Known engine but unparseable version → don't nag; let the runtime
            // probe + failover decide.
            return BrowserSupportAssessment(
                tier: .unknown, engine: engine, majorVersion: nil, minimumSupported: floor)
        }
        let tier: BrowserSupportTier = version >= floor ? .supported : .unsupported
        return BrowserSupportAssessment(
            tier: tier, engine: engine, majorVersion: version, minimumSupported: floor)
    }

    /// The integer immediately following `token` (a major version), or nil.
    /// e.g. ("Chrome/", "…Chrome/140.0.0.0…") -> 140; ("OS ", "iPhone OS 18_2") -> 18.
    private static func majorVersion(after token: String, in ua: String) -> Int? {
        guard let range = ua.range(of: token) else { return nil }
        var digits = ""
        for ch in ua[range.upperBound...] {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits)
    }
}
