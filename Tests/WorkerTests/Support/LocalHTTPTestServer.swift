// Tests/WorkerTests/Support/LocalHTTPTestServer.swift
//
// One throwaway `python3 http.server` for WorkerDaemonTests, replacing three
// near-identical hand-rolled copies (StaticFileServer / FlakyHTTPServer /
// AlwaysFails404Server).
//
// The server is launched through swift-subprocess, like every other process
// the worker and its tests start. It used to be the one Foundation `Process`
// left in the test process, and that was the cause of the WorkerTests stall
// on the resolute image (docs/ci-flakiness.md, Family 6):
//
//   * Foundation detects that a child exited through a socketpair whose one
//     end the child inherits. That end is not close-on-exec. Foundation
//     emulates close-on-exec by listing every open descriptor BEFORE
//     `posix_spawn`, so a descriptor another thread creates in between is
//     inherited too. Measured on this toolchain: four concurrent launches put
//     another launch's socket end into a child in 18 of 300 rounds.
//   * These servers are long-lived. A server that inherited a sibling's end
//     keeps that sibling's exit invisible, so the sibling's `stop()` blocked
//     in `waitUntilExit()` on a cooperative-pool thread for as long as the
//     server lived, and outside every `WedgeWatchdog` scope. Four such waits
//     fill the pool; then no test reaches the `stop()` that would free them.
//
// swift-subprocess closes every descriptor above stderr in the child and
// watches the exit with a pidfd, so neither half can recur. `stop()` also
// no longer waits: it tells the running body to tear the server down, and
// Subprocess reaps it.
//
// The port handshake is unchanged in substance: the child prints its
// ephemeral port to stdout, flushed, as its first line, on a close-on-exec
// pipe this type owns, and `readPort` polls it against a deadline.

import ChickadeeTestSupport
import Foundation
import Subprocess
import Synchronization
import SystemPackage

@testable import chickadee_runner

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A short-lived local HTTP server backed by a real `python3` subprocess,
/// bound to an ephemeral `127.0.0.1` port.  Build one with a factory, read
/// `.port`, and call `.stop()` (typically from a `defer`) when done.
final class LocalHTTPTestServer: Sendable {
    let port: Int
    private let stopSignal: StopSignal

    private init(port: Int, stopSignal: StopSignal) {
        self.port = port
        self.stopSignal = stopSignal
    }

    /// Launches `python3 -c pythonProgram` and returns once it has reported
    /// its port.
    private static func launch(pythonProgram: String, extraArguments: [String]) async throws -> LocalHTTPTestServer {
        let handshake = HandshakePipe()
        let stopSignal = StopSignal()
        let (ports, portSink) = AsyncStream<Int?>.makeStream()

        var options = PlatformOptions()
        // Its own session, so the teardown's group-wide kill reaches only it.
        options.createSession = true

        Task {
            do {
                _ = try await Subprocess.run(
                    .path("/usr/bin/env"),
                    arguments: Arguments(["python3", "-c", pythonProgram] + extraArguments),
                    platformOptions: options,
                    input: .none,
                    output: .fileDescriptor(
                        FileDescriptor(rawValue: handshake.writeEnd), closeAfterSpawningProcess: true),
                    error: .discarded
                ) { execution in
                    let port = readPort(from: handshake.readEnd, deadline: Date().addingTimeInterval(10))
                    handshake.closeReadEnd()
                    portSink.yield(port)
                    portSink.finish()
                    if port != nil { await stopSignal.wait() }
                    // Always ends in SIGKILL: a server parked in a blocking
                    // socket call may not act on SIGTERM.
                    await execution.teardown(using: [])
                }
            } catch {
                // The child never started (python3 missing, spawn refused).
                handshake.closeReadEnd()
            }
            portSink.finish()
        }

        var reported: Int?
        for await port in ports { reported = port }
        guard let port = reported else {
            stopSignal.fire()
            throw IssueRecorded("python3 is unavailable or never reported a port for the local test HTTP server")
        }
        return LocalHTTPTestServer(port: port, stopSignal: stopSignal)
    }

    /// Reads the child's first stdout line and parses it as a port.
    /// Accumulates until a newline so a chunk that arrives before the
    /// newline isn't misread as a failure; a zero-byte read is EOF (the
    /// interpreter exited without printing — e.g. python3 missing).
    ///
    /// Poll-based rather than a blocking read, so the deadline is real even
    /// if the child never prints (one of the #1233 wedge ingredients).
    private static func readPort(from descriptor: Int32, deadline: Date) -> Int? {
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

    /// Stops the server. Never blocks: the running body tears the child down
    /// with SIGKILL and Subprocess reaps it.
    func stop() {
        WedgeWatchdog.noteActivity()
        stopSignal.fire()
    }

    // MARK: - Factories
    // MARK: - Factories

    // Each factory launches its python3 child while holding a subprocess
    // slot (released after the port handshake, not for the server's
    // lifetime), so these long-lived helpers can't join the fork storm
    // `SubprocessThrottle` exists to prevent.

    /// Serves files from `directory` (the runner's submission/test-setup
    /// download source).
    static func staticFiles(directory: URL) async throws -> LocalHTTPTestServer {
        try await withSubprocessSlot {
            try await launch(
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
            try await launch(
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
            try await launch(
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
            try await launch(
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

/// The close-on-exec pipe that carries the port handshake. Subprocess closes
/// the parent's copy of the write end once the child holds its own; the read
/// end is ours, closed once after the handshake or on a failed launch.
private final class HandshakePipe: Sendable {
    let readEnd: Int32
    let writeEnd: Int32
    private let readEndOpen = Mutex(true)

    init() {
        var descriptors: (Int32, Int32) = (-1, -1)
        _ = withUnsafeMutablePointer(to: &descriptors) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 2) { pipe($0) }
        }
        for descriptor in [descriptors.0, descriptors.1] {
            let flags = fcntl(descriptor, F_GETFD)
            if flags != -1 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
        readEnd = descriptors.0
        writeEnd = descriptors.1
    }

    func closeReadEnd() {
        let shouldClose = readEndOpen.withLock { open -> Bool in
            defer { open = false }
            return open
        }
        if shouldClose { close(readEnd) }
    }
}

/// A one-shot signal: `wait()` returns once `fire()` has been called, whether
/// before or after the wait began.
private final class StopSignal: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, Never>)
        case fired
    }

    private let state = Mutex(State.idle)

    func fire() {
        let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
            defer { current = .fired }
            if case .waiting(let continuation) = current { return continuation }
            return nil
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let firedAlready = state.withLock { current -> Bool in
                if case .fired = current { return true }
                current = .waiting(continuation)
                return false
            }
            if firedAlready { continuation.resume() }
        }
    }
}
