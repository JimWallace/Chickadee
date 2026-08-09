// Tests/WorkerTests/Support/LocalHTTPTestServer.swift
//
// One throwaway `python3 http.server` for WorkerDaemonTests, replacing three
// near-identical hand-rolled copies (StaticFileServer / FlakyHTTPServer /
// AlwaysFails404Server).  The copies each carried the same two fragile pieces,
// so a fix had to land three times; here they live once:
//
//   * Port handshake.  The child prints its ephemeral port to stdout, flushed,
//     as its first line.  The old copies did a single `availableData` read,
//     which under load can return *before* the newline is buffered — yielding
//     a truncated/empty parse and a spurious "python3 unavailable" failure.
//     `readPort` instead accumulates chunks until it has a complete line (or
//     hits EOF, meaning the interpreter never started), so a partial read is
//     no longer mistaken for a missing interpreter.
//
//   * Teardown.  The copies busy-waited on `process.isRunning` with
//     `Thread.sleep` before escalating to SIGKILL.  This keeps the SIGKILL
//     (it is load-bearing: a SIGTERM does not reliably tear `socketserver`
//     down while the daemon's HTTP connection is open, so `waitUntilExit()`
//     would block forever without it) but drops the busy-wait — SIGKILL can't
//     be ignored, so the process dies at once and `waitUntilExit()` reaps it
//     without polling.

import ChickadeeTestSupport
import Core
import Foundation

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A short-lived local HTTP server backed by a real `python3` subprocess,
/// bound to an ephemeral `127.0.0.1` port.  Build one with a factory, read
/// `.port`, and call `.stop()` (typically from a `defer`) when done.
///
/// `@unchecked Sendable`: all stored properties are `let` and fully
/// initialized before the instance escapes the factory's subprocess slot;
/// the only post-init mutation is the kill/reap inside `stop()`, which each
/// owning test calls exactly once from its own `defer`.
final class LocalHTTPTestServer: @unchecked Sendable {
    let port: Int
    private let process: Process
    private let stdout: Pipe

    private init(pythonProgram: String, extraArguments: [String], currentDirectory: URL? = nil) throws {
        let process = Process()
        let stdout = Pipe()
        // CLOEXEC: the server child still receives its write end (spawn file
        // actions clear the flag on the descriptor they install), but no
        // *other* concurrently spawned process inherits a duplicate. Without
        // this, a leaked duplicate in a long-lived process means the read
        // loop below never sees EOF if the interpreter dies before printing
        // — an unbounded stall on a cooperative-pool thread (issue #1233).
        setCloseOnExec(stdout)
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", pythonProgram] + extraArguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        try process.run()

        guard
            let port = Self.readPort(
                from: stdout.fileHandleForReading,
                deadline: Date().addingTimeInterval(10))
        else {
            // SIGKILL, not terminate(): a child wedged before its first
            // print may equally ignore SIGTERM, and the caller is about to
            // abandon it.
            kill(process.processIdentifier, SIGKILL)
            throw IssueRecorded("python3 is unavailable or never reported a port for the local test HTTP server")
        }

        self.process = process
        self.stdout = stdout
        self.port = port
    }

    /// Reads the child's first stdout line and parses it as a port.
    /// Accumulates until a newline so a chunk that arrives before the
    /// newline isn't misread as a failure; a zero-byte read is EOF (the
    /// interpreter exited without printing — e.g. python3 missing).
    ///
    /// Poll-based rather than `availableData`: a blocking `availableData`
    /// only re-checks the deadline *between* chunks, so a child that never
    /// prints — or a leaked write-end duplicate that keeps EOF from ever
    /// arriving after the child dies — parked the calling cooperative-pool
    /// thread indefinitely (one of the #1233 wedge ingredients). `poll(2)`
    /// with a 100 ms tick keeps the deadline real.
    private static func readPort(from handle: FileHandle, deadline: Date) -> Int? {
        let descriptor = handle.fileDescriptor
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let readyCount = poll(&pollDescriptor, 1, 100)
            if readyCount == -1 {
                if errno == EINTR { continue }
                return nil
            }
            if readyCount == 0 { continue }  // quiet tick; deadline re-checked at loop top
            let bytesRead = read(descriptor, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk[0..<bytesRead])
                guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
                let lineData = buffer[buffer.startIndex..<newline]
                guard let line = String(data: lineData, encoding: .utf8) else { return nil }
                return Int(line.trimmingCharacters(in: .whitespaces))
            }
            if bytesRead == -1 && errno == EINTR { continue }
            return nil  // 0 = EOF (child exited without printing); -1 = unrecoverable.
        }
        return nil
    }

    func stop() {
        WedgeWatchdog.noteActivity()
        if process.isRunning {
            // SIGKILL, not SIGTERM. The server can be parked in a blocking
            // socket syscall while the daemon's HTTP connection is still open,
            // and there a SIGTERM does not reliably tear `socketserver` down —
            // so `waitUntilExit()` would then block forever. (The three
            // per-server copies this unifies each kept a SIGKILL fallback for
            // exactly this; dropping it is what hung WorkerDaemonTests.)
            // SIGKILL can't be caught or ignored, so the process dies and
            // `waitUntilExit()` reaps it promptly.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        stdout.fileHandleForReading.closeFile()
    }

    // MARK: - Factories

    // Each factory launches its python3 child while holding a subprocess
    // slot (released after the port handshake, not for the server's
    // lifetime), so these long-lived helpers can't join the fork storm
    // `SubprocessThrottle` exists to prevent.

    /// Serves files from `directory` (the runner's submission/test-setup
    /// download source).
    static func staticFiles(directory: URL) async throws -> LocalHTTPTestServer {
        try await withSubprocessSlot {
            try LocalHTTPTestServer(
                pythonProgram: #"""
                    import http.server
                    import socketserver
                    import sys

                    directory = sys.argv[1]

                    class Handler(http.server.SimpleHTTPRequestHandler):
                        def __init__(self, *args, **kwargs):
                            super().__init__(*args, directory=directory, **kwargs)

                        def log_message(self, format, *args):
                            pass

                    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
                        print(httpd.server_address[1], flush=True)
                        httpd.serve_forever()
                    """#,
                extraArguments: [directory.path])
        }
    }

    /// Returns 503 for the first `failuresBeforeSuccess` GETs, then 200 with
    /// `responseBody` — exercises the runner's download-retry path.
    static func flaky(
        failuresBeforeSuccess: Int, responseBody: String = "payload"
    ) async throws -> LocalHTTPTestServer {
        try await withSubprocessSlot {
            try LocalHTTPTestServer(
                pythonProgram: #"""
                    import http.server
                    import socketserver
                    import sys

                    remaining = int(sys.argv[1])
                    body = sys.argv[2].encode("utf-8")

                    class Handler(http.server.BaseHTTPRequestHandler):
                        def do_GET(self):
                            global remaining
                            if remaining > 0:
                                remaining -= 1
                                self.send_response(503)
                                self.end_headers()
                                self.wfile.write(b"unavailable")
                                return
                            self.send_response(200)
                            self.send_header("Content-Length", str(len(body)))
                            self.end_headers()
                            self.wfile.write(body)

                        def log_message(self, format, *args):
                            pass

                    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
                        print(httpd.server_address[1], flush=True)
                        httpd.serve_forever()
                    """#,
                extraArguments: [String(failuresBeforeSuccess), responseBody])
        }
    }

    /// Serves a 200 whose body is written in `chunks` 1 KiB pieces with
    /// `delayMilliseconds` between them, so a transfer stays *in flight* for a
    /// controllable length of time.  Two breadcrumb files in `markerDirectory`
    /// report what the client did:
    ///
    ///   * `started` — written as soon as the response body begins;
    ///   * `completed` — written only if every chunk was accepted, i.e. the
    ///     client did **not** disconnect part-way;
    ///   * `aborted` — written when a write fails, i.e. the client tore the
    ///     transfer down mid-body.
    ///
    /// Those three are what make "was this download cancelled?" observable
    /// from the far side of `URLSession`, which reports a cancelled transfer
    /// and an abandoned one identically.  Used by the Family 4 regression
    /// tests (docs/ci-flakiness.md): a sibling leg's failure must leave
    /// `completed` behind, while cancelling the daemon must leave `aborted`.
    static func slowBody(
        chunks: Int,
        delayMilliseconds: Int,
        markerDirectory: URL
    ) async throws -> LocalHTTPTestServer {
        try await withSubprocessSlot {
            try LocalHTTPTestServer(
                pythonProgram: #"""
                    import http.server
                    import os
                    import socketserver
                    import sys
                    import time

                    chunks = int(sys.argv[1])
                    delay = float(sys.argv[2]) / 1000.0
                    markers = sys.argv[3]
                    payload = b"x" * 1024

                    def mark(name):
                        with open(os.path.join(markers, name), "w") as handle:
                            handle.write("1")

                    class Handler(http.server.BaseHTTPRequestHandler):
                        def do_GET(self):
                            self.send_response(200)
                            self.send_header("Content-Length", str(len(payload) * chunks))
                            self.end_headers()
                            mark("started")
                            try:
                                for _ in range(chunks):
                                    self.wfile.write(payload)
                                    self.wfile.flush()
                                    time.sleep(delay)
                            except Exception:
                                mark("aborted")
                                return
                            mark("completed")

                        def log_message(self, format, *args):
                            pass

                    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
                        print(httpd.server_address[1], flush=True)
                        httpd.serve_forever()
                    """#,
                extraArguments: [String(chunks), String(delayMilliseconds), markerDirectory.path])
        }
    }

    /// Returns 404 for every request — exercises the terminal (non-retryable)
    /// download-failure path.
    static func alwaysNotFound() async throws -> LocalHTTPTestServer {
        try await withSubprocessSlot {
            try LocalHTTPTestServer(
                pythonProgram: #"""
                    import http.server
                    import socketserver

                    class Handler(http.server.BaseHTTPRequestHandler):
                        def do_GET(self):
                            self.send_response(404)
                            self.end_headers()
                            self.wfile.write(b"not found")

                        def log_message(self, format, *args):
                            pass

                    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
                        print(httpd.server_address[1], flush=True)
                        httpd.serve_forever()
                    """#,
                extraArguments: [])
        }
    }
}
