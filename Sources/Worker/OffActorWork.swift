// Worker/OffActorWork.swift
//
// Runs a job's synchronous file-system work off the `WorkerDaemon` actor
// (#2779).
//
// `process(_:)` is isolated to the daemon actor. A synchronous call made from
// it runs on the actor's executor, including a call to a `nonisolated`
// function. With `--max-jobs N`, one slot's recursive workspace removal or
// directory walk then held the actor for its whole duration. While it ran, no
// other slot could send a heartbeat, report a result or read actor state.
//
// The fix keeps every helper synchronous and keeps the order of the steps.
// Only the executor that runs the work changes.

/// Runs `work` on the global concurrent executor, not on the caller's actor,
/// and returns its result. The caller suspends until `work` finishes, so the
/// order of the job's steps does not change. Other tasks can use the
/// caller's actor while `work` runs.
///
/// `@concurrent` states the off-actor hop explicitly. It stays correct after
/// `NonisolatedNonsendingByDefault` is turned on (#1523): under that feature a
/// plain `nonisolated async` function runs on the caller's actor.
@concurrent
func runOffActor<T: Sendable, E: Error>(
    _ work: @Sendable () throws(E) -> T
) async throws(E) -> T {
    try work()
}
