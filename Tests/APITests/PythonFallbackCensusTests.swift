// The `?? .python` census in docs/language-declaration.md matches the code
// (#2494).
//
// CLAUDE.md says every remaining `?? .python` follows the "never fail while
// grading" rule, and the document's Group 3 table gives the reason for each.
// The table had fallen behind: a site added with class activities was not in
// it, and five line numbers were stale. This test fails when a site is added,
// moved to another file or removed without the table changing with it.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct PythonFallbackCensusTests {

    /// Code lines (comments excluded) that default a language to Python, per
    /// file name.
    private func sitesInCode() throws -> [String: Int] {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw IssueRecorded("Cannot list \(sources.path)")
        }
        var counts: [String: Int] = [:]
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            let sites = lines.filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains("?? .python")
            }
            if !sites.isEmpty { counts[file.lastPathComponent] = sites.count }
        }
        return counts
    }

    /// The Group 3 table's rows, as file name to the number of line numbers
    /// listed. Struck-through rows are sites that are gone.
    private func sitesInDocument() throws -> [String: Int] {
        let text = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/language-declaration.md"), encoding: .utf8)
        guard let start = text.range(of: "### Group 3") else {
            throw IssueRecorded("docs/language-declaration.md has no Group 3 section")
        }
        let section = text[start.upperBound...]
        var counts: [String: Int] = [:]
        for line in section.components(separatedBy: "\n") {
            if line.hasPrefix("---") || line.hasPrefix("## ") { break }
            guard line.hasPrefix("| `"), !line.contains("~~") else { continue }
            let cell = line.dropFirst(3).prefix { $0 != "`" }
            let parts = cell.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let file = String(parts[0].split(separator: "/").last ?? parts[0])
            counts[file, default: 0] += parts[1].split(separator: ",").count
        }
        return counts
    }

    @Test func theDocumentListsEverySite() throws {
        let code = try sitesInCode()
        let document = try sitesInDocument()
        #expect(!code.isEmpty)
        #expect(
            code == document,
            """
            The `?? .python` sites in Sources/ do not match the Group 3 table in \
            docs/language-declaration.md. A new site needs a row that gives its reason; \
            a removed one needs its row struck through. Code: \(code.sorted { $0.key < $1.key }). \
            Document: \(document.sorted { $0.key < $1.key }).
            """)
    }
}
