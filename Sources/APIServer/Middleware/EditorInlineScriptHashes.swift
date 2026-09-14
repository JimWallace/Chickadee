// APIServer/Middleware/EditorInlineScriptHashes.swift
//
// Derives the CSP `script-src` hash allow-list for the vendored JupyterLite
// entry points.
//
// Why this exists: #1516 removed `'unsafe-inline'` from the application's
// `script-src`.  Chickadee's own templates no longer carry an executable
// inline script, but `Public/jupyterlite/**/index.html` does — eleven small
// bootstraps, one per app entry point, written by `jupyter lite build` and
// checked in as verified build output.  We do not hand-edit that tree (see
// `check-xeus-vendored.sh`), so the only way to keep the editor booting under
// a strict policy is to allow those exact scripts by hash.
//
// Why a DERIVATION and not a table: a hash pinned in source drifts the moment
// a kernel is re-vendored, and the failure is invisible in the places that
// would catch most things — the editor's own smoke test boots the kernel, but
// a stale hash breaks the page *before* any kernel is fetched, and every
// existing vendoring guard compares the tree to itself.  Reading the bytes
// that FileMiddleware will actually serve means a rebuild carries its own
// hashes with it.  `scripts/revendor-kernels.yml` needs no companion edit.
//
// A nonce cannot do this job: the entry points are static files served by
// FileMiddleware, so there is no per-response rendering step to stamp one
// into.
//
// Scope: hashes are attached only to `/jupyterlite/` responses
// (`SecurityHeadersMiddleware`).  A hash costs ~50 bytes of header and
// permits exactly one script, but the application pages have no inline
// script at all, and a policy that says so is the one worth serving there.
//
// Completeness: `derive` returns nil rather than an empty list when the
// vendored tree is present but yields nothing, and the middleware treats nil
// as "no editor allowance".  A silently-empty derivation reads exactly like a
// correct one, which is the #1330 lesson — see
// `docs/adding-a-xeus-kernel.md`.

import Crypto
import Foundation

/// The CSP `'sha256-…'` source expressions for the inline scripts in a
/// vendored JupyterLite tree.
enum EditorInlineScriptHashes {
    /// The directory, relative to the public directory, whose HTML entry
    /// points carry the inline bootstraps.
    static let vendoredEditorDirectory = "jupyterlite"

    /// Renders one CSP source expression for a script body.
    ///
    /// The hash is taken over the element's text content exactly as the
    /// browser sees it — raw bytes, no trimming, no re-encoding — which is
    /// what the CSP hash algorithm specifies.
    static func sourceExpression(forScriptBody body: Data) -> String {
        "'sha256-" + Data(SHA256.hash(data: body)).base64EncodedString() + "'"
    }

    /// Convenience for a body Chickadee itself emits (the stray-tab page).
    static func sourceExpression(forScriptBody body: String) -> String {
        sourceExpression(forScriptBody: Data(body.utf8))
    }

    /// Scans `publicDirectory/jupyterlite` for HTML entry points and returns
    /// the sorted, de-duplicated hashes of every executable inline script in
    /// them.
    ///
    /// Returns nil when the vendored tree is absent (a test app, or a checkout
    /// without the editor) or when it contains no inline script at all — the
    /// caller must not turn either into an empty allow-list it then reports as
    /// success.
    static func derive(publicDirectory: String) -> [String]? {
        let root = URL(fileURLWithPath: publicDirectory, isDirectory: true)
            .appendingPathComponent(vendoredEditorDirectory, isDirectory: true)
        guard
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return nil }

        var hashes: Set<String> = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "html" {
            guard let html = try? Data(contentsOf: url) else { continue }
            for body in executableInlineScriptBodies(inHTML: html) {
                hashes.insert(sourceExpression(forScriptBody: body))
            }
        }
        return hashes.isEmpty ? nil : hashes.sorted()
    }

    /// The text content of every `<script>` element in `html` that a browser
    /// will execute — no `src` attribute, and either no `type` or a type the
    /// HTML spec treats as JavaScript.
    ///
    /// A `<script type="application/json">` seed is deliberately excluded: it
    /// is a data block, never executed, and `script-src` does not apply to it.
    /// Getting that wrong would be harmless but would pad the header with
    /// hashes of the JupyterLite page-config JSON, which is the one part of
    /// the tree a config-injecting middleware could legitimately rewrite.
    static func executableInlineScriptBodies(inHTML html: Data) -> [Data] {
        guard let text = String(data: html, encoding: .utf8) else { return [] }
        var bodies: [Data] = []
        var cursor = text.startIndex

        while let open = text.range(of: "<script", range: cursor..<text.endIndex) {
            guard let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex),
                let close = text.range(of: "</script", range: openEnd.upperBound..<text.endIndex)
            else { break }
            let attributes = String(text[open.upperBound..<openEnd.lowerBound])
            let body = String(text[openEnd.upperBound..<close.lowerBound])
            if isExecutableInlineScript(attributes: attributes) {
                bodies.append(Data(body.utf8))
            }
            cursor = close.upperBound
        }
        return bodies
    }

    /// Whether a `<script>` tag's attribute text describes an inline script the
    /// browser executes.
    private static func isExecutableInlineScript(attributes: String) -> Bool {
        let lowered = attributes.lowercased()
        // `src=` makes it an external script, governed by the host-source part
        // of `script-src`, not by a hash.
        guard !lowered.contains("src=") else { return false }
        guard let typeRange = lowered.range(of: "type=") else { return true }
        let remainder = lowered[typeRange.upperBound...]
        guard let quote = remainder.first, quote == "\"" || quote == "'" else { return true }
        let valueStart = remainder.index(after: remainder.startIndex)
        guard let valueEnd = remainder[valueStart...].firstIndex(of: quote) else { return true }
        let type = remainder[valueStart..<valueEnd].trimmingCharacters(in: .whitespaces)
        return executableScriptTypes.contains(type)
    }

    /// The `type` values the HTML spec classifies as a classic or module
    /// script.  Everything else is a data block.
    static let executableScriptTypes: Set<String> = [
        "", "module", "text/javascript", "application/javascript",
    ]
}
