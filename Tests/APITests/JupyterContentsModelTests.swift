// Tests/APITests/JupyterContentsModelTests.swift
//
// The Jupyter contents model keeps the keys the JupyterLite client reads
// (#2308), and a JSON file's bytes reach the response as one parsed value.

import Foundation
import Testing

@testable import APIServer

@Suite struct JupyterContentsModelTests {
    private static let keys: Set<String> = [
        "name", "path", "last_modified", "created", "content",
        "format", "mimetype", "size", "writable", "type",
    ]

    private func model(_ content: JupyterContentsModel.Content) -> JupyterContentsModel {
        JupyterContentsModel(
            name: "a.ipynb", path: "dir/a.ipynb", lastModified: "2026-10-06T00:00:00Z",
            created: "2026-10-05T00:00:00Z", content: content, format: "json",
            mimetype: "application/x-ipynb+json", size: 12, writable: true, type: "notebook")
    }

    private func object(_ model: JupyterContentsModel) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: model.jsonData()) as? [String: Any])
    }

    @Test func everyContentKindKeepsTheSameKeys() throws {
        let notebook = try #require(JupyterContentsModel.jsonContent(Data(#"{"cells":[]}"#.utf8)))
        for content: JupyterContentsModel.Content in [
            .none, .text("hi"), .base64("aGk="), .children([model(.none)]), notebook,
        ] {
            #expect(Set(try object(model(content)).keys) == Self.keys)
        }
    }

    @Test func theFieldsKeepTheirValues() throws {
        let fields = try object(model(.none))
        #expect(fields["name"] as? String == "a.ipynb")
        #expect(fields["path"] as? String == "dir/a.ipynb")
        #expect(fields["last_modified"] as? String == "2026-10-06T00:00:00Z")
        #expect(fields["created"] as? String == "2026-10-05T00:00:00Z")
        #expect(fields["content"] is NSNull)
        #expect(fields["format"] as? String == "json")
        #expect(fields["mimetype"] as? String == "application/x-ipynb+json")
        #expect(fields["size"] as? Int == 12)
        #expect(fields["writable"] as? Bool == true)
        #expect(fields["type"] as? String == "notebook")
    }

    @Test func aJSONFileIsWrittenAsOneValue() throws {
        let file = Data("\u{FEFF}{\"cells\": [{\"source\": [\"x = 1\\n\"]}], \"nbformat\": 4}\n".utf8)
        let content = try #require(JupyterContentsModel.jsonContent(file))
        let notebook = try #require(try object(model(content))["content"] as? [String: Any])
        #expect(notebook["nbformat"] as? Int == 4)
        let cells = try #require(notebook["cells"] as? [[String: Any]])
        #expect(cells.first?["source"] as? [String] == ["x = 1\n"])
    }

    @Test(arguments: ["plain text", "42", #""a string""#, "{ broken", ""])
    func onlyAJSONObjectOrArrayIsJSONContent(_ text: String) {
        #expect(JupyterContentsModel.jsonContent(Data(text.utf8)) == nil)
    }

    @Test func utf16JSONIsNotJSONContent() throws {
        let utf16 = try #require(#"{"a":1}"#.data(using: .utf16LittleEndian))
        #expect(JupyterContentsModel.jsonContent(utf16) == nil)
    }
}
