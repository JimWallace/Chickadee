// Tests/APITests/ContentSecurityPolicyInlineScriptTests.swift
//
// Guards the #1516 fix: `'unsafe-inline'` is out of the CSP `script-src`, and
// the vendored JupyterLite entry points keep booting because their inline
// bootstraps are allowed by hash on their own responses only.
//
// The AppScan run of 2026-09-11 reported this as a High (CVSS 8.2) on three
// URLs, but the header is global — every response carried it.  What makes it
// worth a test rather than a one-line fix is that neither direction of a
// regression is loud: putting `'unsafe-inline'` back restores the finding
// silently, and a stale editor hash breaks the editor page BEFORE any kernel
// is fetched, which is upstream of everything the editor smoke test measures.

import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct ContentSecurityPolicyInlineScriptTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // APITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    /// The `script-src` directive out of a rendered policy string.
    private func scriptSrc(in csp: String) -> String? {
        csp.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("script-src ") }
    }

    private func makeApp(editorInlineScriptHashes: [String] = []) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(
            SecurityHeadersMiddleware(editorInlineScriptHashes: editorInlineScriptHashes))
        app.get("headers") { _ in Response(status: .ok, body: .init(string: "ok")) }
        app.get("jupyterlite", "lab", "index.html") { _ in
            Response(status: .ok, body: .init(string: "<html></html>"))
        }
        return app
    }

    // MARK: - The policy itself

    @Test func cSPScriptSrcForbidsInlineExecution() async throws {
        // The reported finding, asserted on a real response rather than on the
        // constant, so a future per-request rewrite cannot reintroduce it
        // behind the constant's back.
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                let directive = try #require(
                    scriptSrc(in: csp), "CSP carries no script-src directive; got: \(csp)")
                #expect(
                    !directive.contains("'unsafe-inline'"),
                    """
                    script-src must not permit inline execution (AppScan High, \
                    CVSS 8.2, #1516). Put page JS in a Public/*.js file and \
                    replace event-handler attributes with delegated listeners; \
                    got: \(directive)
                    """
                )
            }
        }
    }

    @Test func cSPStillPermitsEvalForTheEditor() async throws {
        // Not cosmetic: JupyterLab compiles JSON-schema validators at run time,
        // and narrowing this to 'wasm-unsafe-eval' was measured to leave the
        // editor unable to activate its plugins.  The scan does not flag it.
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(scriptSrc(in: csp)?.contains("'unsafe-eval'") == true)
            }
        }
    }

    @Test func editorInlineScriptHashesRideOnlyTheEditorsOwnResponses() async throws {
        // The hashes are the editor's allowance, not the application's. A page
        // a student logs into must offer no inline allowance of any kind — not
        // even one narrowed to a script it does not serve.
        let hash = "'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='"
        try await withApp(try await makeApp(editorInlineScriptHashes: [hash])) { app in
            try await app.asyncTest(.GET, "/jupyterlite/lab/index.html") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(
                    scriptSrc(in: csp)?.contains(hash) == true,
                    "editor responses must carry the vendored inline-script hashes; got: \(csp)")
            }
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(
                    scriptSrc(in: csp)?.contains(hash) == false,
                    "application responses must carry no inline-script hash; got: \(csp)")
            }
        }
    }

    @Test func scriptSrcRendersHashesAfterTheKeywords() {
        let directive = SecurityHeadersMiddleware.scriptSrc(inlineScriptHashes: ["'sha256-a='"])
        #expect(directive == "script-src 'self' 'unsafe-eval' blob: 'sha256-a='")
        #expect(
            SecurityHeadersMiddleware.scriptSrc(inlineScriptHashes: [])
                == "script-src 'self' 'unsafe-eval' blob:")
    }

    // MARK: - The hash derivation

    @Test func executableInlineScriptExtractionSkipsDataBlocksAndExternalScripts() throws {
        let html = """
            <html><head>
            <script src="/app.js?v=1"></script>
            <script id="seed" type="application/json">{"a":1}</script>
            <script type="module">import('./x.js');</script>
            <script>var a = 1;</script>
            </head></html>
            """
        let bodies =
            EditorInlineScriptHashes
            .executableInlineScriptBodies(inHTML: Data(html.utf8))
            .map { String(bytes: $0, encoding: .utf8) }
        #expect(bodies == ["import('./x.js');", "var a = 1;"])
    }

    @Test func hashIsTakenOverTheScriptBodyExactly() {
        // The CSP hash is over the element's text content verbatim — no
        // trimming, no re-encoding.  `echo -n 'var a = 1;' | openssl dgst
        // -sha256 -binary | openssl base64` is the reference.
        #expect(
            EditorInlineScriptHashes.sourceExpression(forScriptBody: "var a = 1;")
                == "'sha256-+dZ6udsWxNVoGfScAq7t5IIF5UJb4F6RhjbN6oe1p4w='")
    }

    @Test func deriveReportsNothingRatherThanAnEmptyAllowList() throws {
        // A silently-empty derivation reads exactly like a correct one, which
        // is the #1330 lesson.  An absent tree and a tree with no inline
        // script must both answer nil, so the caller cannot report an empty
        // allow-list as a working one.
        #expect(EditorInlineScriptHashes.derive(publicDirectory: "/nonexistent-public") == nil)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-csp-\(UUID().uuidString)", isDirectory: true)
        let editor = empty.appendingPathComponent(
            EditorInlineScriptHashes.vendoredEditorDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: editor, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data("<html><script src=\"/a.js\"></script></html>".utf8)
            .write(to: editor.appendingPathComponent("index.html"))
        #expect(EditorInlineScriptHashes.derive(publicDirectory: empty.path) == nil)
    }

    @Test func vendoredEditorTreeYieldsItsInlineScriptHashes() throws {
        // Completeness, against the bytes FileMiddleware actually serves. The
        // vendored tree has an inline bootstrap per app entry point; a
        // derivation that found none would leave the editor with no allowance
        // at all, and nothing else in the suite would notice.
        let publicDirectory = Self.repoRoot.appendingPathComponent("Public", isDirectory: true)
        let entryPoint =
            publicDirectory
            .appendingPathComponent(EditorInlineScriptHashes.vendoredEditorDirectory)
            .appendingPathComponent("lab/index.html")
        // The vendored editor is large and checked in; a checkout without it
        // is a valid state for this suite to run in, so say nothing.
        guard FileManager.default.fileExists(atPath: entryPoint.path) else { return }

        let hashes = try #require(
            EditorInlineScriptHashes.derive(publicDirectory: publicDirectory.path),
            "the vendored editor tree must yield inline-script hashes")
        #expect(
            hashes.count >= 6,
            "expected one bootstrap per editor entry point, found \(hashes.count)")
        #expect(hashes.allSatisfy { $0.hasPrefix("'sha256-") && $0.hasSuffix("'") })
        #expect(Set(hashes).count == hashes.count, "hashes must be de-duplicated")

        // The hash for the entry point the notebook page actually frames must
        // be in the set — a derivation that walked the wrong subtree, or read
        // a stale copy, would still produce a plausible-looking list.
        let inline =
            EditorInlineScriptHashes
            .executableInlineScriptBodies(inHTML: try Data(contentsOf: entryPoint))
        #expect(inline.count == 1, "lab/index.html should carry exactly one inline bootstrap")
        for body in inline {
            #expect(hashes.contains(EditorInlineScriptHashes.sourceExpression(forScriptBody: body)))
        }
    }
}
