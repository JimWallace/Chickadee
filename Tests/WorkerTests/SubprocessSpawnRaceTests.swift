// Tests/WorkerTests/SubprocessSpawnRaceTests.swift
//
// A Subprocess launch beside a concurrent posix_spawn (docs/ci-flakiness.md,
// Family 6). swift-subprocess creates its child with a raw clone3, so glibc's
// fork handling never runs in that child. Since glibc 2.41, posix_spawn holds
// an internal abort lock while it runs, and sigaction(SIGABRT) takes the same
// lock. A clone3 made while another thread was inside posix_spawn gave the
// child a held copy of the lock; the child's reset of SIGABRT then blocked
// forever before exec, and the launch never returned. Swift Testing starts
// exit tests with posix_spawn, which is how this stalled worker-tests.
//
// Only a host with glibc 2.41 or later can show the defect. The CI image has
// one; on an older glibc this test passes with or without the fix.

import Foundation
import Subprocess
import Synchronization
import Testing

#if canImport(Glibc)
import Glibc
#endif

@Suite(.timeLimit(.minutes(2))) struct SubprocessSpawnRaceTests {
    private final class StopFlag: Sendable {
        let isSet = Atomic<Bool>(false)
    }

    /// Launches `/bin/true` with posix_spawn and waits for it, until `stop` is set.
    private static func spawnUntilStopped(_ stop: StopFlag) {
        let path = "/bin/true"
        while !stop.isSet.load(ordering: .relaxed) {
            var pid: pid_t = 0
            let status = path.withCString { cPath -> Int32 in
                var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
                defer { free(argv[0]) }
                return posix_spawn(&pid, cPath, nil, nil, &argv, nil)
            }
            guard status == 0 else { continue }
            var exitStatus: Int32 = 0
            _ = waitpid(pid, &exitStatus, 0)
        }
    }

    @Test func aLaunchCompletesWhileOtherThreadsPosixSpawn() async throws {
        let stop = StopFlag()
        let spawners = (0..<2).map { _ in
            Thread { Self.spawnUntilStopped(stop) }
        }
        spawners.forEach { $0.start() }
        defer { stop.isSet.store(true, ordering: .relaxed) }

        for _ in 0..<200 {
            let result = try await Subprocess.run(
                .path("/bin/true"), output: .discarded, error: .discarded)
            #expect(result.terminationStatus.isSuccess)
        }
    }
}
