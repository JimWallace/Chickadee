// Tests/APITests/OIDCDiscoveryURLValidationTests.swift
//
// Coverage for the OIDC_AUTH_SERVER URL validator added in issue #563.
// Pure function tests — no network, no env munging.

import Testing

@testable import chickadee_server

@Suite struct OIDCDiscoveryURLValidationTests {

    /// `OIDCDiscoveryURLError` cases all carry an associated value, so we
    /// pattern-match the case rather than asserting equality on a value.
    private func isInsecureScheme(_ error: any Error) -> Bool {
        if case OIDCDiscoveryURLError.insecureScheme = error { return true }
        return false
    }

    private func isPrivateHost(_ error: any Error) -> Bool {
        if case OIDCDiscoveryURLError.privateHost = error { return true }
        return false
    }

    private func isMalformed(_ error: any Error) -> Bool {
        if case OIDCDiscoveryURLError.malformed = error { return true }
        return false
    }

    // MARK: - Happy path

    @Test func accepts_httpsPublicHost() throws {
        try validateOIDCDiscoveryURL(
            "https://sso.example.com/oidc/.well-known/openid-configuration",
            allowInsecure: false
        )
    }

    @Test func accepts_httpsPublicIPv4() throws {
        // A genuine public IPv4 (8.8.8.8) should pass — we only block the
        // private / loopback / link-local ranges.
        try validateOIDCDiscoveryURL(
            "https://8.8.8.8/.well-known/openid-configuration",
            allowInsecure: false
        )
    }

    // MARK: - Insecure scheme

    @Test func rejects_httpScheme() {
        #expect {
            try validateOIDCDiscoveryURL(
                "http://sso.example.com/.well-known/openid-configuration",
                allowInsecure: false
            )
        } throws: { isInsecureScheme($0) }
    }

    @Test func allowsInsecureOverride_httpScheme() throws {
        try validateOIDCDiscoveryURL(
            "http://localhost:8080/.well-known/openid-configuration",
            allowInsecure: true
        )
    }

    // MARK: - Private / loopback hosts

    @Test func rejects_localhost() {
        #expect {
            try validateOIDCDiscoveryURL(
                "https://localhost/.well-known/openid-configuration",
                allowInsecure: false
            )
        } throws: { isPrivateHost($0) }
    }

    @Test func rejects_loopbackIPv4() {
        #expect {
            try validateOIDCDiscoveryURL(
                "https://127.0.0.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        } throws: { isPrivateHost($0) }
    }

    @Test func rejects_class10Range() {
        #expect {
            try validateOIDCDiscoveryURL(
                "https://10.1.2.3/.well-known/openid-configuration",
                allowInsecure: false
            )
        } throws: { isPrivateHost($0) }
    }

    @Test func rejects_class192_168Range() {
        #expect {
            try validateOIDCDiscoveryURL(
                "https://192.168.1.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        } throws: { isPrivateHost($0) }
    }

    @Test func rejects_class172_16to31Range() {
        #expect(throws: (any Error).self) {
            try validateOIDCDiscoveryURL(
                "https://172.20.0.5/.well-known/openid-configuration",
                allowInsecure: false
            )
        }
    }

    @Test func accepts_class172_outsidePrivateRange() throws {
        // 172.32 is outside the 172.16/12 private range — must pass.
        try validateOIDCDiscoveryURL(
            "https://172.32.0.1/.well-known/openid-configuration",
            allowInsecure: false
        )
    }

    @Test func rejects_linkLocal() {
        #expect(throws: (any Error).self) {
            try validateOIDCDiscoveryURL(
                "https://169.254.0.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        }
    }

    @Test func allowsInsecureOverride_loopbackIPv4() throws {
        try validateOIDCDiscoveryURL(
            "https://127.0.0.1/.well-known/openid-configuration",
            allowInsecure: true
        )
    }

    // MARK: - Malformed input

    @Test func rejects_malformedURL() {
        #expect {
            try validateOIDCDiscoveryURL("not a url at all", allowInsecure: false)
        } throws: { isMalformed($0) }
    }
}
