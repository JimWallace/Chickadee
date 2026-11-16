// LoadTest/CookieJar.swift
//
// The cookies one simulated browser holds for the server: the session cookie
// the sign-in sets, kept the way a browser keeps it.

import Foundation
import NIOHTTP1

/// The cookies one simulated browser holds for the server.
struct CookieJar: Sendable, Equatable {
    private(set) var values: [String: String] = [:]

    init() {}

    /// Rebuilds a jar from a saved `Cookie` header.
    init(header: String) {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = String(parts[1])
        }
    }

    /// Takes every `Set-Cookie` in a response. An empty value, or an
    /// expiry in the past, removes the cookie, as a browser does.
    mutating func absorb(_ headers: HTTPHeaders) {
        for line in headers[canonicalForm: "Set-Cookie"] {
            let attributes = line.split(separator: ";")
            guard let first = attributes.first else { continue }
            let parts = first.split(separator: "=", maxSplits: 1)
            guard let name = parts.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let value = parts.count == 2 ? String(parts[1]) : ""
            let expired = attributes.dropFirst().contains {
                $0.trimmingCharacters(in: .whitespaces).lowercased() == "max-age=0"
            }
            if value.isEmpty || expired {
                values[name] = nil
            } else {
                values[name] = value
            }
        }
    }

    /// The `Cookie` request header, or nil when the jar is empty.
    var header: String? {
        guard !values.isEmpty else { return nil }
        return values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }
}
