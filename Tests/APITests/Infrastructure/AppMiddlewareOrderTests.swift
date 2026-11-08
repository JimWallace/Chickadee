// Tests/APITests/Infrastructure/AppMiddlewareOrderTests.swift
//
// The production middleware chain runs as two `AsyncMiddlewareGroup`s around
// Vapor's sessions middleware (#2905), and a group calls its members in the
// listed order. The test app does not run `bootstrapAppMiddleware`, so
// nothing else would notice a member moved, dropped or put in the wrong
// group. This reads the registrations from the source, skipping comment
// lines, and pins their order.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct AppMiddlewareOrderTests {

    /// Every registration, in order: each middleware constructed, each group
    /// registered, and the sessions middleware between the groups.
    private static let expectedOrder = [
        "SecurityHeadersMiddleware(",
        "ErrorPageMiddleware(",
        "HTTPSRedirectMiddleware(",
        "EditorAssetFastPathMiddleware(",
        "RequestTimingMiddleware(",
        "AsyncMiddlewareGroup(outerMiddleware)",
        "app.sessions.middleware",
        "UserSessionAuthenticator(",
        "SessionIdleTimeoutMiddleware(",
        "UserActivityMiddleware(",
        "UserFileNamespaceMiddleware(",
        "AssignmentVersionCaptureMiddleware(",
        "ScanModeMiddleware(",
        "StaticAssetCacheMiddleware(",
        "RunnerWasmCacheMiddleware(",
        "BundleAssetCacheMiddleware(",
        "NotebookAssetIsolationMiddleware(",
        "JupyterLiteConfigFlagMiddleware(",
        "JupyterLiteAppIndexMiddleware(",
        "PrecompressedAssetMiddleware(",
        "KernelLibraryCompressionMiddleware(",
        "FileMiddleware(",
        "COEPMiddleware(",
        "AsyncMiddlewareGroup(innerMiddleware)",
    ]

    @Test func theProductionChainKeepsItsOrder() throws {
        let file = repositoryRoot.appendingPathComponent("Sources/APIServer/Bootstrap/AppMiddleware.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // A type name starts a word, so `func bootstrapAppMiddleware(` does
        // not match.
        let registration =
            /\b[A-Z]\w*Middleware\(|UserSessionAuthenticator\(|AsyncMiddlewareGroup\((?:outer|inner)Middleware\)|app\.sessions\.middleware/
        let found = code.matches(of: registration).map { String($0.output) }
        #expect(found == Self.expectedOrder)
    }
}
