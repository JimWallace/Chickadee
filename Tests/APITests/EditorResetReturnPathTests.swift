import Testing

@testable import APIServer

// Unit coverage for `safeEditorResetReturnPath`, the same-origin sanitizer that
// keeps the /reset-editor "next" parameter from becoming an open redirect (and
// safe to embed in an HTML attribute).  Pure function — no app needed.
@Suite struct EditorResetReturnPathTests {

    @Test func keepsPlainSameOriginPath() {
        #expect(safeEditorResetReturnPath("/testsetups/abc123/notebook") == "/testsetups/abc123/notebook")
    }

    @Test func keepsSameOriginPathWithQuery() {
        #expect(
            safeEditorResetReturnPath("/testsetups/abc/notebook?submissionID=s1")
                == "/testsetups/abc/notebook?submissionID=s1")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(safeEditorResetReturnPath("  /dashboard  ") == "/dashboard")
    }

    @Test(arguments: [
        // protocol-relative → would navigate off-origin
        "//evil.example.com/phish",
        // absolute URLs of various schemes
        "https://evil.example.com",
        "http://evil.example.com",
        "javascript:alert(1)",
        "data:text/html,hi",
        // backslash tricks some URL parsers into treating it as a host sep
        "/\\evil.example.com",
        // not rooted at "/" (relative) — could resolve against the wrong base
        "evil.example.com",
        "testsetups/x/notebook",
        // whitespace / control chars (attribute-injection / header-splitting)
        "/a b",
        "/a\nb",
        "/a\tb",
        // empty / missing
        "",
        "   ",
    ])
    func rejectsUnsafeValuesToRoot(_ raw: String) {
        #expect(safeEditorResetReturnPath(raw) == "/", "expected \(raw.debugDescription) to sanitize to /")
    }

    @Test func rejectsNilToRoot() {
        #expect(safeEditorResetReturnPath(nil) == "/")
    }

    @Test func rejectsOverlongValueToRoot() {
        let long = "/" + String(repeating: "a", count: 600)
        #expect(safeEditorResetReturnPath(long) == "/")
    }
}
