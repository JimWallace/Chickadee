// APIServer/Configuration/OutboundProxyConfig.swift
//
// Optional forward proxy for the server's *outbound* HTTP client.

import Foundation

/// Configures a forward proxy for the server's outbound HTTP client — the OIDC
/// discovery / JWKS / token back-channel and BrightSpace grade-sync calls.
///
/// Needed on networks where direct egress is blocked and all traffic must go
/// through a proxy (e.g. the UWaterloo NAT'd VLAN, where the OIDC discovery
/// fetch otherwise `connectTimeout`s and crash-loops the server at boot).
/// Vapor's HTTP client (AsyncHTTPClient) does NOT honor the standard
/// `HTTP_PROXY`/`HTTPS_PROXY` env vars, and the Docker daemon proxy only covers
/// image pulls — so the proxy has to be applied to the client explicitly.
///
/// Configured via `OUTBOUND_HTTP_PROXY`, e.g. `http://172.16.136.36:3128`.
struct OutboundProxyConfig: Sendable, Equatable {
    let host: String
    let port: Int

    static func fromEnvironment() -> OutboundProxyConfig? {
        guard let raw = trimmedEnv("OUTBOUND_HTTP_PROXY") else { return nil }
        return parse(raw)
    }

    /// Parses `http://host:port`, `host:port`, with or without a trailing slash.
    /// Returns nil if a host and explicit port can't be determined.
    static func parse(_ raw: String) -> OutboundProxyConfig? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: normalized),
            let host = url.host, !host.isEmpty,
            let port = url.port
        else {
            return nil
        }
        return OutboundProxyConfig(host: host, port: port)
    }
}
