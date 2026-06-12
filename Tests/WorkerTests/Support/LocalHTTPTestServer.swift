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

import Foundation

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
            process.terminate()
            throw IssueRecorded("python3 is unavailable or never reported a port for the local test HTTP server")
        }

        self.process = process
        self.stdout = stdout
        self.port = port
    }

    /// Reads the child's first stdout line and parses it as a port.  Loops over
    /// `availableData` until a newline is buffered so a chunk that arrives
    /// before the newline isn't misread as a failure; an empty chunk is EOF
    /// (the interpreter exited without printing — e.g. python3 missing).
    private static func readPort(from handle: FileHandle, deadline: Date) -> Int? {
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
            let lineData = buffer[buffer.startIndex..<newline]
            guard let line = String(data: lineData, encoding: .utf8) else { return nil }
            return Int(line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func stop() {
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
