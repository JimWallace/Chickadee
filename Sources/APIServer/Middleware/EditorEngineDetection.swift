// APIServer/Middleware/EditorEngineDetection.swift
//
// Decides which browser engines must run the JupyterLite editor on the
// service-worker + `comlink` transport instead of the SharedArrayBuffer +
// `coincident` one.
//
// WHY: jupyterlite-pyodide-kernel 0.8 selects `coincident` — synchronous worker
// calls via a SharedArrayBuffer + `Atomics.wait` — whenever the editor iframe is
// cross-origin isolated, and `comlink` (async postMessage) otherwise
// (jupyterlite/pyodide-kernel#126). On WebKit the `coincident` Atomics handshake
// deadlocks the kernel on the FIRST cell execute: it boots to idle cleanly, then
// wedges BUSY forever with no console error (reproduced on Safari 18.2 / Intel;
// the kernel-WebSocket reconnect loop is the signature). So for WebKit we serve
// the editor NON-isolated (→ the kernel picks `comlink`) and re-enable the
// JupyterLite service worker (see `JupyterLiteConfigFlagMiddleware`) to carry the
// synchronous stdin/Drive the no-SharedArrayBuffer path needs. Chrome/Edge/
// Firefox keep the faster SharedArrayBuffer path unchanged.
//
// "WebKit" here means Safari (macOS/iOS) AND every iOS browser: on iOS, Chrome
// (`CriOS`), Firefox (`FxiOS`) and Edge (`EdgiOS`) are all WKWebView — i.e.
// WebKit — so they hit the same deadlock. Desktop Blink (Chrome/Chromium/Edge)
// and Gecko (Firefox) are NOT WebKit here, even though Chrome's UA also contains
// `AppleWebKit` and `Safari/`.

import Vapor

enum EditorBrowserEngine {
    /// True when the User-Agent is a WebKit engine that should get the comlink +
    /// service-worker editor transport rather than the SharedArrayBuffer one.
    ///
    /// Conservative by design: an absent or unrecognized UA returns `false` (the
    /// default SharedArrayBuffer path), so a missing header never silently
    /// degrades the majority Chrome/Edge experience.
    static func isWebKit(userAgent: String?) -> Bool {
        guard let ua = userAgent, !ua.isEmpty else { return false }

        // iOS / iPadOS report a device token and are ALWAYS WKWebView (WebKit),
        // whatever the branded browser. Checked first so iOS Chrome/Edge/Firefox
        // (which also carry `CriOS`/`EdgiOS`/`FxiOS`) classify as WebKit.
        if ua.contains("iPhone") || ua.contains("iPad") || ua.contains("iPod") {
            return true
        }

        // Desktop Blink / Gecko are NOT WebKit. Their UAs also carry
        // `AppleWebKit` and `Safari/`, so they must be excluded explicitly and
        // BEFORE the Safari signature check below. (Android is Blink too.)
        if ua.contains("Chrome/") || ua.contains("Chromium/")
            || ua.contains("Edg/") || ua.contains("Edge/")
            || ua.contains("Firefox/") || ua.contains("OPR/")
            || ua.contains("Android")
        {
            return false
        }

        // What remains with an AppleWebKit + Safari signature is real Safari —
        // desktop, or an iPad sending the "Request Desktop Website" UA.
        // (WebKitGTK / GNOME Web emit `AppleWebKit/` WITHOUT `Safari/` and are
        // intentionally NOT matched — out of scope for this audience. Do not
        // broaden to a bare `AppleWebKit/` check, which would over-match Blink.)
        return ua.contains("AppleWebKit/") && ua.contains("Safari/")
    }

    /// Whether this request should get the comlink + service-worker transport.
    static func isWebKit(_ request: Request) -> Bool {
        isWebKit(userAgent: request.headers.first(name: "User-Agent"))
    }
}
