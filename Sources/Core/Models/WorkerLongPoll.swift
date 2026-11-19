// Core/Models/WorkerLongPoll.swift
//
// The runner poll's long-poll terms, shared by the server and the runner.
//
// A runner slot with no job used to sleep between polls, backing off up to
// 30 s. A submission that arrived while every slot slept waited for the next
// poll before grading began. Now the runner asks the server to hold an idle
// poll open (`WorkerActivityPayload.longPollSeconds`). The server answers as
// soon as it can claim a job for the runner, or with 204 when the hold ends.
// The 204 carries `heldHeader`, so the runner knows the server waited and
// polls again at once instead of backing off.
//
// Each side falls back on its own: an older server ignores the field and
// answers at once without the header, so the runner backs off as before; an
// older runner sends no field, so the server answers at once.

public enum WorkerLongPoll {
    /// The hold the runner asks for. Below the runner's 30 s request timeout,
    /// so a held poll never times out on the runner's side.
    public static let requestedHoldSeconds = 20

    /// The longest hold the server grants, whatever the runner asks for.
    public static let maxHoldSeconds = 20

    /// Set on a 204 from a server that held the poll.
    public static let heldHeader = "Chickadee-Poll-Held"

    /// The hold the server grants for a requested number of seconds: nil for
    /// none (no request, or a request below one second), else the request
    /// capped at `maxHoldSeconds`.
    public static func grantedHoldSeconds(requested: Int?) -> Int? {
        guard let requested, requested >= 1 else { return nil }
        return min(requested, maxHoldSeconds)
    }
}
