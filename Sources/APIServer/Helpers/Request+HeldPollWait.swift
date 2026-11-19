// APIServer/Helpers/Request+HeldPollWait.swift
//
// The time a held runner poll (`WorkerLongPoll`) spent waiting for work.
// `RequestTimingMiddleware` subtracts it, so the poll route's timing in the
// hot-path stats and `request_metrics` measures the server's work, as it did
// before polls were held, and not the up-to-20 s hold.

import Vapor

private struct HeldPollWaitKey: StorageKey {
    typealias Value = Duration
}

extension Request {
    /// The time this request spent waiting in a held runner poll. Zero for
    /// every other request.
    var heldPollWait: Duration {
        storage[HeldPollWaitKey.self] ?? .zero
    }

    /// Adds one wait of a held runner poll.
    func addHeldPollWait(_ wait: Duration) {
        storage[HeldPollWaitKey.self] = heldPollWait + wait
    }
}
