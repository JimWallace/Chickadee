import Testing

@testable import APIServer

/// `EditorBrowserEngine.isWebKit` decides which engines get the editor's
/// comlink + service-worker transport (WebKit) vs the SharedArrayBuffer path
/// (Blink/Gecko). The classifier must treat every iOS browser as WebKit
/// (WKWebView) while excluding desktop Chrome/Edge/Firefox — whose UAs also
/// contain `AppleWebKit` and `Safari/`.
@Suite struct EditorEngineDetectionTests {

    @Test(arguments: [
        // Desktop Safari (the reported repro: Safari 18.2 / Intel).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
        // iOS Safari.
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
        // iPadOS Safari.
        "Mozilla/5.0 (iPad; CPU OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
        // iOS Chrome (CriOS) — WKWebView, so still WebKit.
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/604.1",
        // iOS Firefox (FxiOS) — WKWebView.
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/130.0 Mobile/15E148 Safari/604.1",
        // iOS Edge (EdgiOS) — WKWebView.
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 EdgiOS/130.0 Mobile/15E148 Safari/604.1",
        // Playwright's WebKit engine (drives the editor-smoke WebKit leg).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    ])
    func detectsWebKit(_ ua: String) {
        #expect(EditorBrowserEngine.isWebKit(userAgent: ua))
    }

    @Test(arguments: [
        // Desktop Chrome (macOS + Windows).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        // Desktop Edge.
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0",
        // Desktop Firefox.
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:130.0) Gecko/20100101 Firefox/130.0",
        // Android Chrome (Blink).
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36",
        // Playwright's Chromium engine (drives the editor-smoke Chromium leg).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/130.0.0.0 Safari/537.36",
    ])
    func excludesNonWebKit(_ ua: String) {
        #expect(!EditorBrowserEngine.isWebKit(userAgent: ua))
    }

    @Test func absentUserAgentDefaultsToNonWebKit() {
        #expect(!EditorBrowserEngine.isWebKit(userAgent: nil))
        #expect(!EditorBrowserEngine.isWebKit(userAgent: ""))
    }
}
