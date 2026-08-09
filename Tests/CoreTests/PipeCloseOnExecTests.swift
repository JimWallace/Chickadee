// Tests/CoreTests/PipeCloseOnExecTests.swift
//
// The point of `setCloseOnExec` is not the flag, it is the EOF: a capture
// pipe whose write end an unrelated child inherited cannot reach EOF until
// that child exits, and a reader blocked on that EOF is the ingredient that
// turns a transient overload into a permanent wedge (#1139 / #1233).
//
// Measured while adding these tests, and worth knowing before assuming the
// leak is live: on Swift 6.3 / glibc 2.39 BOTH spawners this codebase uses
// already prevent it themselves. Foundation's `Process` leaves a child with
// only fds 0/1/2, and swift-subprocess `close_range(…, CLOSE_RANGE_CLOEXEC)`s
// everything above stderr. A child spawned by a bare `posix_spawn` still
// inherits the lot — that is the case the helper covers, and the case the
// behavioural test below uses, because it is the only one that can still
// demonstrate the failure.

import Foundation
import Testing

@testable import Core

#if canImport(Glibc)
import Glibc
#endif

@Suite struct PipeCloseOnExecTests {

    private func hasCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags != -1 && (flags & FD_CLOEXEC) != 0
    }

    /// Reads until EOF or the deadline. Returns whether EOF was reached, so a
    /// leaked write end shows up as `false` rather than as a hung test.
    private func reachesEOF(_ descriptor: Int32, withinSeconds seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready > 0 {
                let count = read(descriptor, &chunk, chunk.count)
                if count == 0 { return true }  // every write end closed
                if count < 0 && errno == EINTR { continue }
                if count < 0 { return false }
            }
        }
        return false
    }

    @Test func closeOnExecPipeSetsTheFlagOnBothEnds() {
        let pipe = closeOnExecPipe()
        #expect(hasCloseOnExec(pipe.fileHandleForReading.fileDescriptor))
        #expect(hasCloseOnExec(pipe.fileHandleForWriting.fileDescriptor))
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    /// The premise. A bare `Pipe()` is not CLOEXEC, which is why every
    /// hand-built capture pipe has to be passed through the helper — if this
    /// ever starts failing, Foundation changed and the helper is redundant.
    @Test func bareFoundationPipeIsNotCloseOnExec() {
        let pipe = Pipe()
        #expect(!hasCloseOnExec(pipe.fileHandleForWriting.fileDescriptor))
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    /// The behaviour, with its control. Against a spawner that does not close
    /// inherited descriptors, a bare capture pipe cannot reach EOF while the
    /// unrelated child lives; a CLOEXEC one reaches it as soon as the parent
    /// closes its own end. The bare-pipe assertion is the control: if it ever
    /// starts reaching EOF, this test has stopped measuring anything and the
    /// assertion above it is worthless.
    @Test func closeOnExecLetsTheReaderReachEOFWhileAnInheritingChildLives() {
        #if os(Linux)
        guard FileManager.default.fileExists(atPath: "/bin/sleep") else { return }

        let guarded = closeOnExecPipe()
        let bare = Pipe()

        // A raw posix_spawn with no file actions: the child inherits every
        // open descriptor, including both pipes' write ends.
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sleep"), strdup("20"), nil,
        ]
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        guard posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0 else { return }
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        // Drop the parent's write ends. Now the ONLY thing that could keep
        // either pipe from EOF is the duplicate the child inherited.
        try? guarded.fileHandleForWriting.close()
        try? bare.fileHandleForWriting.close()

        #expect(reachesEOF(guarded.fileHandleForReading.fileDescriptor, withinSeconds: 3))
        #expect(!reachesEOF(bare.fileHandleForReading.fileDescriptor, withinSeconds: 3))

        try? guarded.fileHandleForReading.close()
        try? bare.fileHandleForReading.close()
        #endif
    }

    /// Records the measurement the comment at the top of this file rests on,
    /// so a toolchain change that re-opens the leak is caught here rather than
    /// discovered in a wedged CI job: a child spawned through Foundation's
    /// `Process` must not be holding a non-CLOEXEC pipe of ours.
    @Test func foundationProcessDoesNotLeakDescriptorsToItsChild() throws {
        #if os(Linux)
        guard FileManager.default.fileExists(atPath: "/bin/sh") else { return }
        let bare = Pipe()
        defer {
            try? bare.fileHandleForReading.close()
            try? bare.fileHandleForWriting.close()
        }
        let listing = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ls /proc/self/fd"]
        process.standardOutput = listing
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = listing.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let inherited = Set(
            (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").compactMap { Int32($0) })
        #expect(!inherited.contains(bare.fileHandleForWriting.fileDescriptor))
        #endif
    }
}
