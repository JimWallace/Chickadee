import Testing

@testable import APIServer

/// `SupportedBrowserMatrix` decides whether a browser is at/above Chickadee's
/// supported floor (modeled on D2L Brightspace's matrix, simplified to
/// supported / unsupported — we never block). Detection is conservative: only a
/// confidently-identified below-floor browser is `.unsupported`; an unknown or
/// unparseable UA is `.unknown` (no warning), since the runtime probe + grading
/// failover are the real safety net.
@Suite struct SupportedBrowserMatrixTests {

    // MARK: - Supported (at or above the floor)

    @Test(arguments: [
        // Desktop Chrome above floor (149 ≥ 140).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
        // Chrome exactly at the floor (140).
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        // Desktop Edge above floor (Edg/149) — checked before Chrome/.
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/149.0.0.0",
        // Desktop Firefox at floor (143).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:143.0) Gecko/20100101 Firefox/143.0",
        // Desktop Safari at the floor (Version/26).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        // iOS Safari at the floor (Version/26).
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
        // Android Chrome above floor.
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36",
    ])
    func classifiesSupported(_ ua: String) {
        #expect(SupportedBrowserMatrix.assess(userAgent: ua).tier == .supported)
        #expect(!SupportedBrowserMatrix.isUnsupported(userAgent: ua))
    }

    // MARK: - Unsupported (known engine, below floor)

    @Test(arguments: [
        // The reported repro: desktop Safari 18.2 (< 26).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
        // iOS Safari 17.5 (< 26).
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
        // iPadOS Safari 18 (< 26).
        "Mozilla/5.0 (iPad; CPU OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
        // iOS Chrome (CriOS) with no Version/ token — falls back to the iOS OS major (18 < 26).
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/604.1",
        // Desktop Chrome below floor (139 < 140).
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
        // Desktop Edge below floor (Edg/139).
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36 Edg/139.0.0.0",
        // Desktop Firefox below floor (142 < 143).
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:142.0) Gecko/20100101 Firefox/142.0",
    ])
    func classifiesUnsupported(_ ua: String) {
        #expect(SupportedBrowserMatrix.assess(userAgent: ua).tier == .unsupported)
        #expect(SupportedBrowserMatrix.isUnsupported(userAgent: ua))
    }

    // MARK: - Unknown (don't nag — degrade-safe)

    @Test(arguments: [
        "",
        // No recognized browser engine.
        "curl/8.4.0",
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    ])
    func classifiesUnknown(_ ua: String) {
        #expect(SupportedBrowserMatrix.assess(userAgent: ua).tier == .unknown)
        #expect(!SupportedBrowserMatrix.isUnsupported(userAgent: ua))
    }

    @Test func absentUserAgentIsUnknown() {
        #expect(SupportedBrowserMatrix.assess(userAgent: nil).tier == .unknown)
        #expect(!SupportedBrowserMatrix.isUnsupported(userAgent: nil))
    }

    // MARK: - Assessment detail (for the banner copy + telemetry)

    @Test func reportsEngineVersionAndFloorForAnUnsupportedBrowser() {
        let a = SupportedBrowserMatrix.assess(
            userAgent:
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"
        )
        #expect(a.tier == .unsupported)
        #expect(a.engine == "Safari")
        #expect(a.majorVersion == 18)
        #expect(a.minimumSupported == SupportedBrowserMatrix.minimumSafari)
    }

    @Test func aKnownEngineWithAnUnparseableVersionIsUnknownNotUnsupported() {
        // "Chrome/" present but no numeric version follows → don't nag.
        let a = SupportedBrowserMatrix.assess(
            userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/ Safari/537.36")
        #expect(a.tier == .unknown)
        #expect(a.engine == "Chrome")
        #expect(a.majorVersion == nil)
    }
}
