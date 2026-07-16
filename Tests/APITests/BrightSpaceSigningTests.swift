// Tests/APITests/BrightSpaceSigningTests.swift
//
// Pins the D2L Valence signing primitives against vectors computed from
// Brightspace's reference SDK (valence-sdk-python): the per-request signature
// base string, the HMAC-SHA256 / base64url helper, and the authorization-URL
// builder. None of these hit a live D2L, so a regression in the signing format
// — which historically only a real server would have caught — fails here.

import Foundation
import Testing

@testable import APIServer

@Suite struct BrightSpaceSigningTests {

    @Test func requestBaseString_isMethodAmpPathAmpTimestamp() {
        let base = valenceRequestBaseString(
            method: "get", path: "/d2l/api/lp/1.28/users/whoami", timestamp: 1_700_000_000)
        // Method uppercased, path lowercased, '&'-separated, timestamp seconds.
        #expect(base == "GET&/d2l/api/lp/1.28/users/whoami&1700000000")
    }

    @Test func hmacBase64URL_matchesReferenceVector_andIsURLSafe() {
        let sig = brightSpaceHMACSHA256Base64URL(
            key: "appKey", message: "GET&/d2l/api/lp/1.28/users/whoami&1700000000")
        // Vector from Python: base64.urlsafe_b64encode(HMAC-SHA256(...)).rstrip('=')
        #expect(sig == "c1TGef0nOLcWvxZOOaBS8aFHIMYgmkPIm3PjFzJ7FEM")
        #expect(!sig.contains("+"))
        #expect(!sig.contains("/"))
        #expect(!sig.contains("="))
    }

    @Test func valenceAuthURL_signsCallbackAndFullyEncodesTarget() {
        let creds = BrightSpaceAppCredentials(
            baseURL: "https://learntest.uwaterloo.ca",
            appID: "93ecUKpmD8WZlBV00Jj-Hg",
            appKey: "appKey",
            debounceSecs: 90)
        let callback = "https://chickadee.uwaterloo.ca/admin/brightspace/valence-callback?state=abc"
        let url = creds.valenceAuthURL(callback: callback)

        #expect(url.hasPrefix("https://learntest.uwaterloo.ca/d2l/auth/api/token?"))
        #expect(url.contains("x_a=93ecUKpmD8WZlBV00Jj-Hg"))
        // x_b = HMAC(appKey, raw callback) — reference vector.
        #expect(url.contains("x_b=9SKVW-dP0v5zy882hlfXZA6uBhoAtbw_ZiJrpBL1xr8"))
        // x_target fully percent-encodes ':' '/' '?' '=' so the inner ?state=
        // can't leak into the surrounding auth-URL query.
        #expect(
            url.contains(
                "x_target=https%3A%2F%2Fchickadee.uwaterloo.ca%2Fadmin%2Fbrightspace%2Fvalence-callback%3Fstate%3Dabc"
            ))
    }

    @Test func syncConfigFromAppCredentials_carriesAllFields() {
        let creds = BrightSpaceAppCredentials(
            baseURL: "https://x", appID: "a", appKey: "ak", debounceSecs: 42)
        let config = BrightSpaceSyncConfig(app: creds, userID: "u", userKey: "k")
        #expect(config.baseURL == "https://x")
        #expect(config.appID == "a")
        #expect(config.appKey == "ak")
        #expect(config.userID == "u")
        #expect(config.userKey == "k")
        #expect(config.debounceSecs == 42)
    }
}
