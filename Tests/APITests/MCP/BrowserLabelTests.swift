// Tests/APITests/MCP/BrowserLabelTests.swift
//
// Guards GetBrowserDiagnosticsTool.browserLabel — the coarse browser/OS parser
// that powers the `byBrowser` breakdown, so editor failures can be localized to
// a browser/device class (e.g. "Kernel Unknown" concentrated on one platform).

import Testing

@testable import APIServer

@Suite struct BrowserLabelTests {

    private func label(_ ua: String?) -> String {
        GetBrowserDiagnosticsTool.browserLabel(forUserAgent: ua)
    }

    @Test func parsesCommonUserAgents() {
        // Chrome on Windows.
        #expect(
            label(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36") == "Chrome/Windows")
        // Safari on iOS (UA contains no Chrome/Edge tokens).
        #expect(
            label(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1")
                == "Safari/iOS")
        // Safari on macOS.
        #expect(
            label(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15") == "Safari/macOS")
        // Edge wins over Chrome/Safari (its UA contains both).
        #expect(
            label(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                    + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0") == "Edge/Windows")
        // Firefox on Linux.
        #expect(
            label("Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0")
                == "Firefox/Linux")
        // Chrome on Android wins over Linux (Android UA also contains "Linux").
        #expect(
            label(
                "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) "
                    + "Chrome/120.0.0.0 Mobile Safari/537.36") == "Chrome/Android")
    }

    @Test func handlesMissingUserAgent() {
        #expect(label(nil) == "Unknown")
        #expect(label("") == "Unknown")
    }
}
