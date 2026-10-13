// LoadTest/LoadTarget.swift
//
// Validates the server URL before any request goes out. A simulated runner
// can claim a real pending job, and the load itself competes with students,
// so the tool refuses a server that is not on this machine unless the
// operator says otherwise.

import Foundation

enum LoadTargetError: Error, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case remoteHostRefused(String)

    var description: String {
        switch self {
        case .invalidURL(let value):
            return "Not an http or https URL: \(value)"
        case .remoteHostRefused(let host):
            return
                "Refusing to load \(host): it is not a loopback host. Use a local or staging server. "
                + "If this host is not production, run again with --allow-remote."
        }
    }
}

struct LoadTarget: Sendable, Equatable {
    let baseURL: URL

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    init(baseURL value: String, allowRemote: Bool) throws(LoadTargetError) {
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else {
            throw .invalidURL(value)
        }
        guard allowRemote || Self.loopbackHosts.contains(host) else {
            throw .remoteHostRefused(host)
        }
        self.baseURL = url
    }

    /// The absolute URL for a server path such as `/api/v1/worker/request`.
    func url(forPath path: String) -> String {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base + path
    }
}
