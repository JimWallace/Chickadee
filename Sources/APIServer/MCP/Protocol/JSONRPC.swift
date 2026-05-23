// APIServer/MCP/Protocol/JSONRPC.swift
//
// JSON-RPC 2.0 framing types for the MCP endpoint.  One coherent set of
// Codable types covers requests, notifications, responses, and errors.
//
// Transport note: the MCP Streamable HTTP transport (2025-11-25) carries a
// single JSON-RPC message per HTTP POST body — batching was removed in that
// revision — so these types model one message, never an array.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

import Core
import Foundation

// MARK: - Message ID

/// A JSON-RPC request identifier.  Per the spec an `id` is a string, a number,
/// or null.  A message with no `id` key at all is a *notification* and is
/// modelled as a nil `JSONRPCRequest.id` — distinct from an explicit `.null`.
enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case number(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be a string, integer, or null."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Request / Notification

/// A decoded inbound JSON-RPC message.  When `id` is nil the message is a
/// *notification* and MUST NOT receive a response.
struct JSONRPCRequest: Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?

    /// True when the message carries no `id` key (a notification).
    var isNotification: Bool { id == nil }
}

extension JSONRPCRequest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        // Distinguish "id key absent" (a notification) from "id present and
        // null".  `decodeIfPresent` would collapse both to nil, so check key
        // presence explicitly and let `JSONRPCID` decode an explicit null.
        id = container.contains(.id) ? try container.decode(JSONRPCID.self, forKey: .id) : nil
    }
}

// MARK: - Response

/// A JSON-RPC response.  Exactly one of `result` / `error` is populated; the
/// `success` / `failure` factories enforce that invariant.
struct JSONRPCResponse: Sendable {
    let id: JSONRPCID?
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONRPCID?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    static func failure(id: JSONRPCID?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }
}

extension JSONRPCResponse: Encodable {
    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        // The spec requires an `id` on every response; it is null when the
        // request id could not be determined (e.g. a parse error).
        try container.encode(id ?? .null, forKey: .id)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
    }
}

// MARK: - Error

/// A JSON-RPC error object.  Codes follow the JSON-RPC 2.0 spec; MCP layers its
/// authorization semantics on top via HTTP status codes (401/403), not custom
/// JSON-RPC codes.
struct JSONRPCError: Error, Encodable, Equatable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 error codes.
    static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        JSONRPCError(code: -32_700, message: message)
    }

    static func invalidRequest(_ message: String = "Invalid Request") -> JSONRPCError {
        JSONRPCError(code: -32_600, message: message)
    }

    static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32_601, message: "Method not found: \(method)")
    }

    static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32_602, message: "Invalid params: \(message)")
    }

    static func internalError(_ message: String = "Internal error") -> JSONRPCError {
        JSONRPCError(code: -32_603, message: message)
    }

    // MCP authorization: the authenticated token lacks a scope the requested
    // tool requires.  JSON-RPC reserves -32000…-32099 for server-defined errors;
    // the transport maps this code to an HTTP 403 `insufficient_scope` response.
    static let insufficientScopeCode = -32_001

    /// `requiredScopes` is the space-delimited scope string the tool demands; it
    /// is surfaced in the response `data` and the `WWW-Authenticate` challenge.
    static func insufficientScope(_ requiredScopes: String) -> JSONRPCError {
        JSONRPCError(code: insufficientScopeCode, message: "Insufficient scope.", data: .string(requiredScopes))
    }
}

// MARK: - Typed decoding of JSON payloads

extension JSONValue {
    /// Decodes this JSON value into a `Decodable` type by round-tripping through
    /// `JSONEncoder` / `JSONDecoder`.  The dispatcher uses this to turn raw
    /// `params` and tool `arguments` into a tool's own typed input, so handlers
    /// never touch untyped JSON.
    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Builds a JSON value from any `Encodable` by round-tripping through
    /// `JSONEncoder` / `JSONDecoder`.  The dispatcher uses this to turn a typed
    /// result struct into the `JSONValue` payload of a JSON-RPC response.
    init(encoding value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A compact JSON string for this value — used for the human-readable
    /// `text` content block in a `tools/call` result.
    func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
