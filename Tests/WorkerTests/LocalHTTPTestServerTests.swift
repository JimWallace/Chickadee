// Tests/WorkerTests/LocalHTTPTestServerTests.swift
//
// The test HTTP server's lifecycle (docs/ci-flakiness.md, Family 6). `stop()`
// used to wait for the child's exit on a cooperative-pool thread, and that
// wait never ended when a sibling server had inherited the child's exit
// signal. Now `stop()` never waits, and the server still dies, however many
// siblings are running.

import Foundation
import Testing

@Suite(.timeLimit(.minutes(2))) struct LocalHTTPTestServerTests {
    /// True while something accepts TCP connections on `port`.
    private static func isListening(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func waitUntilClosed(_ port: Int, seconds: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isListening(port) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isListening(port)
    }

    /// The socket descriptors held by each child of this process serving
    /// `directory`, keyed by pid. An idle server needs exactly one: its
    /// listening socket. The directory is unique to the calling test, so other
    /// tests' servers — busy with a request, or already dying — are not
    /// counted.
    private static func serverChildSockets(serving directory: URL) -> [Int32: Int] {
        let me = getpid()
        var result: [Int32: Int] = [:]
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc"))?.compactMap(Int32.init) ?? []
        for pid in pids {
            guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let closingParen = stat.lastIndex(of: ")")
            else { continue }
            let fields = stat[stat.index(after: closingParen)...].split(separator: " ")
            guard fields.count > 1, Int32(fields[1]) == me,
                let commandLine = try? String(contentsOfFile: "/proc/\(pid)/cmdline", encoding: .utf8),
                commandLine.contains("socketserver"), commandLine.contains(directory.path)
            else { continue }
            let descriptorDirectory = "/proc/\(pid)/fd"
            let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: descriptorDirectory)) ?? []
            result[pid] =
                descriptors.filter { name in
                    guard let number = Int(name), number > 2 else { return false }
                    let target = try? FileManager.default.destinationOfSymbolicLink(
                        atPath: "\(descriptorDirectory)/\(name)")
                    return target?.hasPrefix("socket:") == true
                }.count
        }
        return result
    }

    /// The root cause of the Family 6 stall, pinned: Foundation's `Process`
    /// gave every child one end of its exit-detection socketpair, and let
    /// another launch's end leak into it. A server launched through
    /// Subprocess holds its listening socket and nothing else.
    @Test func aServerHoldsOnlyItsListeningSocket() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-http-sockets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let servers = try await withThrowingTaskGroup(of: LocalHTTPTestServer.self) { group in
            for _ in 0..<4 {
                group.addTask { try await LocalHTTPTestServer.staticFiles(directory: directory) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        defer { servers.forEach { $0.stop() } }

        let sockets = Self.serverChildSockets(serving: directory)
        #expect(sockets.count == servers.count, "found \(sockets.count) server children")
        for (pid, count) in sockets {
            #expect(count == 1, "server \(pid) holds \(count) sockets")
        }
    }

    @Test func aStoppedServerStopsListening() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-http-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let server = try await LocalHTTPTestServer.staticFiles(directory: directory)
        #expect(Self.isListening(server.port))

        server.stop()

        #expect(await Self.waitUntilClosed(server.port))
    }

    /// Four servers launched at once — the concurrency that let one inherit
    /// another's exit signal — each stop at once and die while the others
    /// are still serving.
    @Test func eachOfSeveralConcurrentServersStopsOnItsOwn() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-http-servers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let servers = try await withThrowingTaskGroup(of: LocalHTTPTestServer.self) { group in
            for _ in 0..<4 {
                group.addTask { try await LocalHTTPTestServer.staticFiles(directory: directory) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        for (index, server) in servers.enumerated() {
            server.stop()
            #expect(await Self.waitUntilClosed(server.port), "server \(index) is still listening")
            for sibling in servers[(index + 1)...] {
                #expect(Self.isListening(sibling.port), "stopping one server stopped a sibling")
            }
        }
    }
}
