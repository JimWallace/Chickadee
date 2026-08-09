// Tests/TestSupport/WedgeWatchdog.swift
//
// Process-level wedge watchdog, shared by every test target (issues #1233,
// and the 2026-08-09 `api-tests` incident recorded as Family 5 in
// docs/ci-flakiness.md).
//
// Twice in one afternoon `worker-tests` rode to the CI job-level 20-minute
// kill with ~250 tests started, ~55 completed, and the process otherwise
// silent for 18 minutes: every cooperative-pool thread was pinned in a
// blocking syscall, so no task — including Swift Testing's `.timeLimit`
// enforcement and the `awaitCancelledDaemon` bound, both of which need a
// pool thread to run — could make progress. The only artifact was the
// *absence* of output. `api-tests` then burned a 20-minute `cancelled` job
// of its own with the same guard gap: 33 files carrying `.timeLimit`, which
// cannot fire under saturation, and zero references to this watchdog, which
// can.
//
// This watchdog runs on a dedicated OS thread (`Thread.detachNewThread`), so
// pool saturation cannot starve it. Callers that own a scope which can
// participate in a wedge (a test body holding a Vapor app, a subprocess
// launch, a daemon shutdown, a poll loop) report activity; if such scopes are
// in flight and NO activity has been reported for `stallLimitSeconds`, the
// watchdog dumps every thread's kernel-visible state
// (`/proc/self/task/*/{comm,wchan,stat}` — `wchan` names the syscall wait
// each pinned thread is parked in), flushes stdout so buffered structured-log
// lines aren't lost, and aborts. A wedge then fails in minutes with a thread
// table pointing at the pinned syscalls, instead of burning 20 minutes and
// reporting nothing.
//
// **It measures silence, not slowness.** The Family 5 shape — a lane running
// at ~10x cost but still completing tests — resets the clock on every scope
// entry and exit, so it can never trip this. Only a run in which nothing
// starts or finishes for `stallLimitSeconds` does. That distinction is the
// whole point: a starved-but-progressing job must stay a slow pass, and a
// wedged one must become a fast failure carrying evidence.
//
// The stall limit (default 300 s) exceeds every legitimate quiet stretch by a
// wide margin. Measured, not guessed: a full 2,732-test `APITests` run at CI's
// parallelization width passes with the limit forced down to **30 s** — the
// monitor wakes every 15 s, so that bounds the longest silent gap in a healthy
// run at well under a minute, against a shipped limit of five. Individual
// tests in that same run reported up to 131 s of wall clock and still did not
// trip it, which is the distinction working: a long test is not a silent
// process. The lane's median wall-clock in CI is ~236 s, so 300 s of total
// silence is longer than a healthy run takes end to end. On the WorkerTests
// side, per-suite `.timeLimit` is 3 minutes and the longest bounded helper
// wait is 30 s.
//
// Naming note: the override is CHICKADEE_WORKERTESTS_STALL_SECONDS (0
// disables the abort entirely). The name predates the watchdog being shared
// and now under-describes its scope — it governs every test target in the
// process, not just WorkerTests. It is deliberately NOT renamed and NOT
// joined by a second variable: CLAUDE.md's standing rule is that new
// environment variables are not introduced, and renaming this one would
// silently drop any existing override. Read it as "the test-process stall
// limit".

import Foundation
import Synchronization

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum WedgeWatchdog {
    private struct State {
        var monitorStarted = false
        var activeHelpers = 0
        var lastActivity = Date()
        var firing = false
    }

    private static let state = Mutex(State())

    public static let stallLimitSeconds: TimeInterval = {
        guard
            let raw = ProcessInfo.processInfo.environment["CHICKADEE_WORKERTESTS_STALL_SECONDS"],
            let parsed = TimeInterval(raw)
        else { return 300 }
        return parsed
    }()

    /// How many `track` scopes are currently in flight. The watchdog is armed
    /// exactly when this is non-zero. Exposed so a target can assert its own
    /// arming seam is still wired — the guard is worth having because losing
    /// the arming is silent: everything keeps passing, and the next wedge is
    /// again a 20-minute job kill with no evidence.
    public static var activeTrackedScopes: Int {
        state.withLock { $0.activeHelpers }
    }

    /// Seconds since the last reported activity. This is what the monitor
    /// thread compares against `stallLimitSeconds`.
    public static var secondsSinceLastActivity: TimeInterval {
        state.withLock { Date().timeIntervalSince($0.lastActivity) }
    }

    /// Report liveness. Call from helper poll loops and entry/exit points —
    /// any call resets the stall clock.
    public static func noteActivity() {
        state.withLock { current in
            current.lastActivity = Date()
            startMonitorIfNeeded(&current)
        }
    }

    /// Wrap a scope that can participate in a wedge: while at least one
    /// tracked call is in flight the watchdog is armed, and a tracked call
    /// that stops producing activity is what the stall clock measures.
    ///
    /// Both the entry and the exit count as activity, so a target whose only
    /// tracked scope is "one test body" still resets the clock on every test
    /// that starts or finishes. Once the last tracked scope returns the
    /// watchdog disarms, so a process winding down after its final test can
    /// never be aborted for being idle.
    public static func track<R>(_ body: () async throws -> R) async rethrows -> R {
        state.withLock { current in
            current.activeHelpers += 1
            current.lastActivity = Date()
            startMonitorIfNeeded(&current)
        }
        defer {
            state.withLock { current in
                current.activeHelpers -= 1
                current.lastActivity = Date()
            }
        }
        return try await body()
    }

    private static func startMonitorIfNeeded(_ current: inout State) {
        guard !current.monitorStarted, stallLimitSeconds > 0 else { return }
        current.monitorStarted = true
        Thread.detachNewThread {
            monitorLoop()
        }
    }

    private static func monitorLoop() {
        while true {
            Thread.sleep(forTimeInterval: 15)
            let stall: (seconds: TimeInterval, helpers: Int)? = state.withLock { current in
                guard current.activeHelpers > 0, !current.firing else { return nil }
                let elapsed = Date().timeIntervalSince(current.lastActivity)
                guard elapsed >= stallLimitSeconds else { return nil }
                current.firing = true
                return (elapsed, current.activeHelpers)
            }
            if let stall {
                abortWedgedProcess(stalledSeconds: stall.seconds, activeHelpers: stall.helpers)
            }
        }
    }

    private static func abortWedgedProcess(stalledSeconds: TimeInterval, activeHelpers: Int) {
        dumpThreadStates(
            reason: "no test activity for \(Int(stalledSeconds))s with \(activeHelpers) tracked "
                + "scope(s) in flight — cooperative pool presumed wedged; aborting so CI gets "
                + "evidence instead of the 20-minute job kill (issues #1233 / ci-flakiness "
                + "Family 5).\n"
                + "        This is SILENCE, not slowness: a lane merely running slowly keeps "
                + "starting and finishing tests, which resets the clock. Read the wchan column "
                + "below — threads parked in pipe_read / do_wait / futex are the pinned ones.\n"
                + "        Stall limit was \(Int(stallLimitSeconds))s "
                + "(CHICKADEE_WORKERTESTS_STALL_SECONDS)")
        // Buffered structured-log lines are evidence too — the #1233 wedges
        // each surfaced their last log line only at kill time. Flushing can
        // itself block if stdout is the contended resource; the dump above
        // already reached stderr via raw write(2), and the job-level timeout
        // remains the outer backstop.
        fflush(nil)
        abort()
    }

    /// Writes every thread's kernel-visible state to stderr with raw
    /// `write(2)` calls — stdio locks are avoided deliberately, since a
    /// wedged thread may be holding them.
    public static func dumpThreadStates(reason: String) {
        var report = "\n==== WedgeWatchdog thread dump (issue #1233) ====\n"
        report += "reason: \(reason)\n"
        let taskDir = "/proc/self/task"
        if let tids = try? FileManager.default.contentsOfDirectory(atPath: taskDir).sorted(
            by: { (Int($0) ?? 0) < (Int($1) ?? 0) })
        {
            report += "thread table (state D/S = blocked; wchan = kernel wait it is parked in):\n"
            for tid in tids {
                let comm = readProcFile("\(taskDir)/\(tid)/comm") ?? "?"
                let wchan = readProcFile("\(taskDir)/\(tid)/wchan") ?? "?"
                let stat = readProcFile("\(taskDir)/\(tid)/stat") ?? ""
                report += "  tid \(tid) state=\(threadStateCharacter(fromStat: stat)) "
                report += "wchan=\(wchan) comm=\(comm)\n"
            }
        } else {
            report += "(/proc/self/task unavailable on this platform — no per-thread table)\n"
        }
        report += "==== end thread dump ====\n"
        writeToStandardError(report)
    }

    private static func readProcFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Field 3 of `/proc/.../stat`, located after the parenthesised comm —
    /// the comm itself may contain spaces or parens, so scan from the last
    /// closing paren.
    private static func threadStateCharacter(fromStat stat: String) -> String {
        guard let closingParen = stat.lastIndex(of: ")") else { return "?" }
        let tail = stat[stat.index(after: closingParen)...]
            .trimmingCharacters(in: .whitespaces)
        return tail.first.map(String.init) ?? "?"
    }

    private static func writeToStandardError(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(2, base, buffer.count)
            }
            if written <= 0 { return }
            offset += written
        }
    }
}
