// Tests/APITests/UnownedTaskGuardTests.swift
//
// No task the server starts may be left with no owner (#1948). A `Task { }`
// whose handle nobody keeps can outlive the application, and one that uses
// `application.db` then queries a closed database: the query fails, and a
// second read of `app.db` on the failure path traps in Fluent's accessor
// (#1700). #1700, #1922 and #1923 gave every such task an owner that shutdown
// waits for (`DataExportManager`, `PeriodicSweepMonitor`, `BackgroundWork`).
// This guard keeps it that way.
//
// It reads `Sources/APIServer` for a task created in statement position: a
// line that starts `Task {`, `Task(`, `Task.detached` or `_ = Task`. A task
// that is assigned, returned or added to a group has an owner, and the scan
// does not report it. A file may start one only if `allowed` says why that is
// safe; the list is empty.

import Foundation
import Testing

@Suite struct UnownedTaskGuardTests {

    /// Source file (relative to `Sources/APIServer`) → why its unowned task is
    /// safe. Prefer `application.backgroundWork.start { … }` to an entry here.
    static let allowed: [String: String] = [:]

    private static let serverSources: URL = {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }  // -> repo root
        return url.appendingPathComponent("Sources/APIServer")
    }()

    /// The 1-based line numbers in `source` that start a task nobody keeps.
    static func unownedTaskLines(in source: String) -> [Int] {
        let starts = ["Task {", "Task(", "Task.detached", "_ = Task"]
        return source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return starts.contains { trimmed.hasPrefix($0) } ? index + 1 : nil
        }
    }

    @Test func everyServerTaskHasAnOwner() throws {
        let root = Self.serverSources
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)  // the scan had real input

        var unowned: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard Self.allowed[relative] == nil else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in Self.unownedTaskLines(in: source) {
                unowned.append("\(relative):\(line)")
            }
        }

        #expect(
            unowned.isEmpty,
            """
            These lines start a task that nothing keeps, so it can outlive the application: \
            \(unowned.sorted()). Start it with `application.backgroundWork.start { … }`, or \
            keep its handle in an owner that shutdown waits for. If it is truly safe, add the \
            file to UnownedTaskGuardTests.allowed and say why.
            """)
    }

    /// Every allowed file must still start an unowned task, or its entry is stale.
    @Test func everyAllowedFileStillNeedsItsEntry() throws {
        for relative in Self.allowed.keys {
            let file = Self.serverSources.appendingPathComponent(relative)
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!Self.unownedTaskLines(in: source).isEmpty, "\(relative) no longer needs its entry")
        }
    }

    /// The guard above, seen to fail: a scan that finds nothing would pass it.
    @Test func theScanFindsUnownedTasksAndIgnoresOwnedOnes() {
        let synthetic = """
            func start() {
                Task {
                    await work()
                }
                Task(priority: .background) { await work() }
                Task.detached { await work() }
                _ = Task { await work() }
                let kept = Task { await work() }
                running[id] = Task { await work() }
                group.addTask { await work() }
                // Task { await work() }
                /// a bare `Task { }` in a doc comment
                return Task { await work() }
            }
            """
        #expect(Self.unownedTaskLines(in: synthetic) == [2, 5, 6, 7])
    }
}
