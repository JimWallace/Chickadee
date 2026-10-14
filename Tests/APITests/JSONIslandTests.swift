import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

/// A JSON island carries author text into a script element. It must parse to
/// the same value and must not let that text end or change the element.
@Suite struct JSONIslandTests {

    private static func content(of html: String) throws -> String {
        let open = try #require(html.range(of: #"type="application/json">"#))
        let close = try #require(html.range(of: "</script>", options: .backwards))
        return String(html[open.upperBound..<close.lowerBound])
    }

    @Test(arguments: [
        #"{"name":"</script><script>alert(1)</script>"}"#,
        #"{"name":"<!-- <script> -->","n":1}"#,
        #"{"plain":"a & b > c","list":[1,2]}"#,
    ])
    func theIslandParsesToTheSameValueAndCannotEndTheScript(json: String) throws {
        let html = JSONIsland(id: "seed", json: json).render()
        let content = try Self.content(of: html)
        #expect(!content.contains("<"))
        #expect(html.components(separatedBy: "</script>").count == 2)
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        let originalIsObject = if case .object = original { true } else { false }
        #expect(originalIsObject)
        #expect(parsed == original)
    }

    @Test func theIslandCarriesItsIDAndType() {
        let html = JSONIsland(id: "suite-state-seed", json: "[]").render()
        #expect(html == #"<script id="suite-state-seed" type="application/json">[]</script>"#)
    }
}
