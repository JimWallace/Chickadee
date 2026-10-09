// APIServer/LTI/LTIServiceHost.swift
//
// Which hosts an LTI service call may reach (docs/compliance/
// lti-audit-2026-10.md L-1). A platform sends service URLs in its launches
// and its responses: the AGS line-items URL, each line item's `id`, the NRPS
// membership URL and its `next` pages. Chickadee attaches the platform's
// bearer token, and a score carries a student's LMS subject and grade, so
// each URL must name a host that an admin registered for that platform.

import Foundation

enum LTIServiceHost {
    /// The hosts for which `LTIPlatformForm.secureURL` accepts plain `http`.
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// The lowercased host of `url`, or nil when it has none.
    static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// The hosts of `urls`, skipping any that has none.
    static func hosts(of urls: [String]) -> Set<String> {
        Set(urls.compactMap(host(of:)))
    }

    /// True when `url` is `https`, or `http` on a loopback host, and its host
    /// is one of `hosts`.
    static func permits(_ url: String, hosts: Set<String>) -> Bool {
        guard
            let parsed = URL(string: url),
            let scheme = parsed.scheme?.lowercased(),
            let host = host(of: url), hosts.contains(host)
        else { return false }
        return scheme == "https" || (scheme == "http" && loopbackHosts.contains(host))
    }
}

extension APILTIPlatform {
    /// The hosts of the URLs an admin registered for this platform. A
    /// Brightspace platform serves its services from the LMS host, which its
    /// issuer, login and key-set URLs name; its token URL is on another host.
    var registeredHosts: Set<String> {
        LTIServiceHost.hosts(of: [issuer, authLoginURL, accessTokenURL, jwksURL])
    }
}
