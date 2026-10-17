// Tests/APITests/DatasetCourseSeedCallSiteTests.swift
//
// Every server call that resolves dataset slices names the course seed
// (docs/datasets-course-library.md, slice 4). The resolver and the
// personalization helpers keep an older signature without it, for callers
// that predate the course cohort; a production call site that used it would
// silently give a course-scoped dataset per-assignment rows. This scan finds
// each call and requires the `courseSeedHex:` label inside its argument list.

import ChickadeeTestSupport
import Foundation
import Testing

@Suite struct DatasetCourseSeedCallSiteTests {

    /// The calls that resolve dataset slices for a student.
    private static let calls = [
        "DatasetResolver.resolve(",
        "PersonalizationSubstitution.resolve(",
        "PersonalizationSubstitution.gradingInputs(",
    ]

    /// The argument list of the call that opens at `start`, up to its
    /// matching close parenthesis.
    private static func argumentList(in source: String, from start: String.Index) -> Substring {
        var depth = 0
        var index = start
        while index < source.endIndex {
            switch source[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return source[start...index] }
            default: break
            }
            index = source.index(after: index)
        }
        return source[start...]
    }

    @Test func everyServerCallSiteNamesTheCourseSeed() throws {
        let root = repositoryRoot.appendingPathComponent("Sources/APIServer")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found = 0
        var missing: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for call in Self.calls {
                var searchFrom = source.startIndex
                while let range = source.range(of: call, range: searchFrom..<source.endIndex) {
                    searchFrom = range.upperBound
                    // `static func resolve(` declarations are not calls.
                    let lineStart = source[..<range.lowerBound].lastIndex(of: "\n") ?? source.startIndex
                    if source[lineStart..<range.lowerBound].contains("func ") { continue }
                    found += 1
                    let open = source.index(before: range.upperBound)
                    if !Self.argumentList(in: source, from: open).contains("courseSeedHex:") {
                        missing.append("\(url.lastPathComponent): \(call)")
                    }
                }
            }
        }
        // The scan must find the known call sites, not pass on an empty walk.
        #expect(found >= 6, "found only \(found) call sites")
        #expect(missing.isEmpty, "these calls do not pass the course seed: \(missing)")
    }
}
