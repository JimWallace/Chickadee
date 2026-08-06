// APIServer/Middleware/COEPMiddleware.swift
//
// Adds Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers
// to dynamic (Leaf-rendered) pages that require cross-origin isolation.
//
// Cross-origin isolation (COOP same-origin + COEP require-corp) is what makes
// `SharedArrayBuffer` available, which the kernel needs to run synchronous code
// (stdin / filesystem) without blocking the page. Two pages opt in:
//
//   • /instructor/…/validate — browser-side validation (assignment-validate.js).
//   • /testsetups/:id/notebook — the student notebook editor (JupyterLite in an
//     iframe), when `isolateNotebook` is true (set unconditionally at the
//     bootstrap call site). `NotebookAssetIsolationMiddleware` +
//     `EditorAssetFastPathMiddleware` apply the matching headers to the
//     `/jupyterlite/*` documents and the vendored asset trees so the iframe
//     document — where the kernel worker actually runs — is isolated too.
//
// COEP require-corp only restricts CROSS-origin subresources; same-origin ones
// (Chickadee vendors the kernels / CodeMirror / jszip same-origin) load unchanged.
//
// History: isolation was gated behind `NOTEBOOK_CROSS_ORIGIN_ISOLATION` while
// the editor was verified to boot under COEP, because COEP on the editor page
// had broken the iframe before (#574). It is now applied to every engine EXCEPT
// WebKit (Safari/iOS), which is served NON-isolated so its kernel uses the
// comlink transport — the SharedArrayBuffer/`coincident` path deadlocks on
// WebKit (see EditorBrowserEngine). Do NOT make this unconditional again without
// re-breaking Safari. For the isolated engines the editor's
// SharedArrayBuffer path is verified end-to-end by the editor-smoke harness
// (Tools/editor-smoke-test), and SAB removes the kernel's dependence on the
// service worker for synchronous stdin/Drive — see
// docs/notebook-editor-kernel-boot.md. The `isolateNotebook` parameter is kept
// as a unit-test seam.

import Vapor

struct COEPMiddleware: AsyncMiddleware {
    /// Whether the student notebook editor page opts into cross-origin isolation.
    let isolateNotebook: Bool

    init(isolateNotebook: Bool = false) {
        self.isolateNotebook = isolateNotebook
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        guard needsCOEP(path: request.url.path) else { return response }
        // The editor's cross-origin isolation now varies by engine — WebKit gets
        // the non-isolated comlink + service-worker path (see EditorBrowserEngine)
        // — so any shared cache must key these responses on the User-Agent.
        response.headers.add(name: "Vary", value: "User-Agent")
        // WebKit deadlocks on the SharedArrayBuffer/`coincident` kernel transport,
        // so it must NOT be cross-origin isolated. Leaving COEP off makes
        // `crossOriginIsolated` false in the iframe and the kernel falls back to
        // `comlink`; Chrome/Edge/Firefox keep the isolated SharedArrayBuffer path.
        guard !EditorBrowserEngine.isWebKit(request) else { return response }
        response.headers.replaceOrAdd(
            name: "Cross-Origin-Opener-Policy",
            value: "same-origin"
        )
        response.headers.replaceOrAdd(
            name: "Cross-Origin-Embedder-Policy",
            value: "require-corp"
        )
        return response
    }

    /// Returns true for paths whose pages opt into cross-origin isolation.
    private func needsCOEP(path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let last = parts.last ?? ""

        // Instructor validate page — loads assignment-validate.js.
        // Matched by last path component rather than a prefix so it does not
        // sweep in the rest of /instructor/*, which has no need of isolation.
        // (The historic reason given here — that those pages load CDN
        // resources — no longer holds: the CSP is `'self'`-only and every
        // browser library is vendored same-origin.  The narrow match is still
        // right, just not for that reason.)
        if last == "validate" { return true }

        // Student notebook editor page (/testsetups/:id/notebook), gated.
        if isolateNotebook, parts.count == 3, parts[0] == "testsetups", last == "notebook" {
            return true
        }

        // Assignment workbench (/instructor/:assignmentID/workbench).
        //
        // It needs the headers, and the reason is the whole point of this
        // block: cross-origin isolation is a property of the *entire ancestor
        // chain*.  The workbench hosts the JupyterLite editor iframe, so
        //
        //   • without isolation on the shell, the notebook iframe cannot be
        //     isolated either, `crossOriginIsolated` goes false inside it, and
        //     every Chrome/Firefox author silently drops off the
        //     SharedArrayBuffer path onto the service-worker comlink transport
        //     (docs/notebook-editor-kernel-boot.md) — a performance and
        //     reliability regression with no error message; and
        //   • under `require-corp` a nested document must itself send
        //     `require-corp` or the browser refuses to load it outright
        //     (`ERR_BLOCKED_BY_RESPONSE.CoepFrameResourceNeedsCoepHeader`).
        //
        // #1266 merged the workbench into one document, so the chain is one
        // link shorter — the `…/workbench/panel` arm below went with the route
        // it matched.  The requirement on the workbench itself is unchanged.
        //
        // Gated on the same flag as the notebook page: the page and its editor
        // frame must agree, and the unit-test seam has to be able to turn the
        // whole thing off in one place.  WebKit is exempted by the caller, which
        // is what keeps Safari's comlink path working — there it is simply
        // "no isolation anywhere in the chain", which is equally consistent.
        if isolateNotebook, parts.count == 3, parts[0] == "instructor", last == "workbench" {
            return true
        }

        return false
    }
}
