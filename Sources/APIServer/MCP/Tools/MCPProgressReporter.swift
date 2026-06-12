// APIServer/MCP/Tools/MCPProgressReporter.swift
//
// Emits MCP `notifications/progress` messages during a long-running tool call.
// Built by the transport only when the call arrived over a progress-capable SSE
// stream — the client both advertised `Accept: text/event-stream` and supplied a
// `progressToken` in the request's `params._meta`. The reporter frames each
// update as a JSON-RPC notification and hands it to a sink that writes it to the
// open SSE stream.
//
// `Sendable` so it can be captured by the `@Sendable` streamed-response closure.

import Core

struct MCPProgressReporter: Sendable {
    /// The opaque token the client attached to the request; echoed back on every
    /// progress notification so the client can correlate it with the call.
    let token: JSONValue
    private let sink: @Sendable (JSONValue) async -> Void

    init(token: JSONValue, sink: @escaping @Sendable (JSONValue) async -> Void) {
        self.token = token
        self.sink = sink
    }

    /// Sends one `notifications/progress`. `progress` is a fraction toward
    /// `total` (default 1.0); `message` is a short human-readable status.
    func report(_ progress: Double, total: Double = 1, message: String) async {
        let notification: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object([
                "progressToken": token,
                "progress": .double(progress),
                "total": .double(total),
                "message": .string(message),
            ]),
        ])
        await sink(notification)
    }

    /// Extracts the client's `progressToken` from a request's `params`
    /// (`params._meta.progressToken`), or nil when absent. Per the MCP spec a
    /// server only sends progress when the client opted in with a token.
    static func token(fromParams params: JSONValue?) -> JSONValue? {
        guard case .object(let p)? = params, case .object(let meta)? = p["_meta"],
            let token = meta["progressToken"]
        else { return nil }
        return token
    }
}
