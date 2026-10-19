// Tests/TestSupport/SwiftSourceFiles.swift
//
// One definition for the suites that scan source. Six suites used to declare
// their own `swiftFiles`: four read the whole tree and two read one level, and
// three returned nothing for a directory they could not read.

import Foundation
import SystemPackage

/// The Swift files under `directory`, at any depth, sorted by path.
///
/// Throws when `directory` is not a directory, so a wrong path fails the test
/// rather than scanning nothing and passing.
public func swiftFiles(under directory: URL) throws -> [URL] {
    guard let status = try? Stat(FilePath(directory.path)), status.type == .directory,
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { throw IssueRecorded("Cannot read the directory \(directory.path)") }
    return enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
}
