// Worker/OffActorWork.swift
//
// Runs a job's synchronous file-system work off the `WorkerDaemon` actor
// (#2779), and off Swift's cooperative thread pool.
//
// `process(_:)` is isolated to the daemon actor. A synchronous call made from
// it runs on the actor's executor, including a call to a `nonisolated`
// function. With `--max-jobs N`, one slot's recursive workspace removal or
// directory walk then held the actor for its whole duration. While it ran, no
// other slot could send a heartbeat, report a result or read actor state.
//
// Moving the work to the global concurrent executor freed the actor, but not
// the pool. On Linux that executor is as wide as the machine has cores, and a
// recursive copy or delete of a test setup with a course dataset holds its
// thread for tens to hundreds of milliseconds. With `--max-jobs` at or above
// the core count, concurrent jobs filled the pool, and every other task waited
// for a thread: the script watchdog, the exit poll, the heartbeats. The pipe
// drains in `ScriptCapture` leave the pool on dedicated threads for the same
// reason, and so does this work.
//
// The fix keeps every helper synchronous and keeps the order of the steps.
// Only the thread that runs the work changes.

import Foundation

/// Runs `work` on a dedicated thread, not on the caller's actor and not on
/// the cooperative thread pool, and returns its result. The caller suspends
/// until `work` finishes, so the order of the job's steps does not change.
/// Other tasks can use the caller's actor, and the pool thread the caller
/// would otherwise have held, while `work` runs.
///
/// `work` sees the caller's `RunnerLogCapture`, so its structured log lines go
/// where the caller's would. That is the one task-local the runner binds. A
/// thread outside any task does not inherit task-locals, so it is bound again
/// on the thread. Like the executor hop this replaced, the call does not
/// respond to cancellation: `work` always runs to its end.
func runOffActor<T: Sendable, E: Error>(
    _ work: @escaping @Sendable () throws(E) -> T
) async throws(E) -> T {
    let capture = RunnerLogCapture.current
    let result: Result<T, E> = await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            RunnerLogCapture.$current.withValue(capture) {
                continuation.resume(returning: Result(catching: work))
            }
        }
    }
    return try result.get()
}
