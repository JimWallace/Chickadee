import XCTest
import XCTVapor
@testable import chickadee_server
import Vapor
import Foundation

final class JupyterLiteContentsRoutesTests: XCTestCase {
    private var app: Application!
    private var tmpRoot: String!
    private var publicDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlite-\(UUID().uuidString)/")
            .path
        app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
        publicDir = app.directory.publicDirectory

        try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: publicDir + "jupyterlite/files/",
            withIntermediateDirectories: true
        )
        try app.register(collection: JupyterLiteContentsRoutes())
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpRoot)
    }

    func testAllJSONListsNotebook() async throws {
        let notebookName = "setup_test-assignment.ipynb"
        let notebookData = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}
        """.data(using: .utf8)!
        try notebookData.write(to: URL(fileURLWithPath: publicDir + "jupyterlite/files/" + notebookName))

        try await app.test(.GET, "/jupyterlite/lab/api/contents/all.json", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let bodyData = Data(res.body.string.utf8)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "directory")
            let content = try XCTUnwrap(object["content"] as? [[String: Any]])
            XCTAssertTrue(content.contains { ($0["name"] as? String) == notebookName })
        })
    }

    func testNotebookMetadataAndContent() async throws {
        let notebookName = "setup_test-assignment.ipynb"
        let notebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"markdown","metadata":{},"source":["hello"]}]}
        """
        try notebookJSON.data(using: .utf8)!.write(
            to: URL(fileURLWithPath: publicDir + "jupyterlite/files/" + notebookName)
        )

        try await app.test(.GET, "/jupyterlite/lab/api/contents/\(notebookName)", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let bodyData = Data(res.body.string.utf8)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "notebook")
            XCTAssertEqual(object["format"] as? String, "json")
            XCTAssertTrue(object["content"] is NSNull)
        })

        try await app.test(.GET, "/jupyterlite/lab/api/contents/\(notebookName)?content=1", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let bodyData = Data(res.body.string.utf8)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "notebook")
            let content = try XCTUnwrap(object["content"] as? [String: Any])
            let cells = try XCTUnwrap(content["cells"] as? [[String: Any]])
            XCTAssertEqual(cells.count, 1)
        })
    }
}
