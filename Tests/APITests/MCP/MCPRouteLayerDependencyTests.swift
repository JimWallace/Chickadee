// No MCP file uses a symbol that is defined under Routes/Web (#2496).
//
// Code that both surfaces use belongs in a shared layer. The MCP tools used to
// call the suite edit, the runner-fleet rows and the storage breakdown where
// the web routes defined them, so a change to a web route could break an MCP
// tool. Those now live in Services/.
//
// The scan reads the top-level declarations of every file under Routes/Web and
// looks for each name in the MCP files. A name after a `.` is a member, not a
// use of the top-level symbol, so `headers.contentType` does not count as a use
// of the web `contentType(for:)`.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct MCPRouteLayerDependencyTests {

    private let apiServer = repositoryRoot.appendingPathComponent("Sources/APIServer")

    private func swiftFiles(under directory: String) throws -> [URL] {
        let root = apiServer.appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw IssueRecorded("Cannot list \(root.path)")
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The names of the non-private top-level declarations in Routes/Web.
    private func webRouteNames() throws -> Set<String> {
        let declaration = try Regex(
            #"^(?:@\w+\s+)*(?:final\s+)?(?:func|struct|enum|class|actor|protocol|typealias)\s+([A-Za-z_]\w*)"#)
        var names: Set<String> = []
        for file in try swiftFiles(under: "Routes/Web") {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                if let match = line.firstMatch(of: declaration), let name = match.output[1].substring {
                    names.insert(String(name))
                }
            }
        }
        return names
    }

    @Test func noMCPFileUsesAWebRouteSymbol() throws {
        let names = try webRouteNames()
        #expect(!names.isEmpty)
        // An identifier not after a `.` or another identifier character.
        let identifier = try Regex(#"(?:^|[^.\w])([A-Za-z_]\w*)"#).anchorsMatchLineEndings()
        var offenders: [String] = []
        for file in try swiftFiles(under: "MCP") {
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let used = Set(code.matches(of: identifier).compactMap { $0.output[1].substring.map(String.init) })
            for name in used.intersection(names) {
                offenders.append("\(file.lastPathComponent) uses \(name)")
            }
        }
        #expect(
            offenders.isEmpty,
            "Move what both surfaces use out of Routes/Web (for example into Services/): \(offenders.sorted())")
    }
}
