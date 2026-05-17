// Tests/APITests/OIDCDiscoveryURLValidationTests.swift
//
// Coverage for the OIDC_AUTH_SERVER URL validator added in issue #563.
// Pure function tests — no network, no env munging.

import XCTest

@testable import chickadee_server

final class OIDCDiscoveryURLValidationTests: XCTestCase {

    // MARK: - Happy path

    func testAccepts_httpsPublicHost() {
        XCTAssertNoThrow(
            try validateOIDCDiscoveryURL(
                "https://sso.example.com/oidc/.well-known/openid-configuration",
                allowInsecure: false
            )
        )
    }

    func testAccepts_httpsPublicIPv4() {
        // A genuine public IPv4 (8.8.8.8) should pass — we only block the
        // private / loopback / link-local ranges.
        XCTAssertNoThrow(
            try validateOIDCDiscoveryURL(
                "https://8.8.8.8/.well-known/openid-configuration",
                allowInsecure: false
            )
        )
    }

    // MARK: - Insecure scheme

    func testRejects_httpScheme() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "http://sso.example.com/.well-known/openid-configuration",
                allowInsecure: false
            )
        ) { err in
            guard case OIDCDiscoveryURLError.insecureScheme = err else {
                XCTFail("Expected insecureScheme, got \(err)")
                return
            }
        }
    }

    func testAllowsInsecureOverride_httpScheme() {
        XCTAssertNoThrow(
            try validateOIDCDiscoveryURL(
                "http://localhost:8080/.well-known/openid-configuration",
                allowInsecure: true
            )
        )
    }

    // MARK: - Private / loopback hosts

    func testRejects_localhost() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://localhost/.well-known/openid-configuration",
                allowInsecure: false
            )
        ) { err in
            guard case OIDCDiscoveryURLError.privateHost = err else {
                XCTFail("Expected privateHost, got \(err)")
                return
            }
        }
    }

    func testRejects_loopbackIPv4() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://127.0.0.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        ) { err in
            guard case OIDCDiscoveryURLError.privateHost = err else {
                XCTFail("Expected privateHost, got \(err)")
                return
            }
        }
    }

    func testRejects_class10Range() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://10.1.2.3/.well-known/openid-configuration",
                allowInsecure: false
            )
        ) { err in
            guard case OIDCDiscoveryURLError.privateHost = err else {
                XCTFail("Expected privateHost, got \(err)")
                return
            }
        }
    }

    func testRejects_class192_168Range() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://192.168.1.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        ) { err in
            guard case OIDCDiscoveryURLError.privateHost = err else {
                XCTFail("Expected privateHost, got \(err)")
                return
            }
        }
    }

    func testRejects_class172_16to31Range() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://172.20.0.5/.well-known/openid-configuration",
                allowInsecure: false
            )
        )
    }

    func testAccepts_class172_outsidePrivateRange() {
        // 172.32 is outside the 172.16/12 private range — must pass.
        XCTAssertNoThrow(
            try validateOIDCDiscoveryURL(
                "https://172.32.0.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        )
    }

    func testRejects_linkLocal() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL(
                "https://169.254.0.1/.well-known/openid-configuration",
                allowInsecure: false
            )
        )
    }

    func testAllowsInsecureOverride_loopbackIPv4() {
        XCTAssertNoThrow(
            try validateOIDCDiscoveryURL(
                "https://127.0.0.1/.well-known/openid-configuration",
                allowInsecure: true
            )
        )
    }

    // MARK: - Malformed input

    func testRejects_malformedURL() {
        XCTAssertThrowsError(
            try validateOIDCDiscoveryURL("not a url at all", allowInsecure: false)
        ) { err in
            guard case OIDCDiscoveryURLError.malformed = err else {
                XCTFail("Expected malformed, got \(err)")
                return
            }
        }
    }
}
