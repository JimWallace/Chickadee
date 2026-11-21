// APIServer/Utilities/RandomURLSafeToken.swift
//
// The one spelling of an unguessable token: 32 bytes from the system CSPRNG,
// base64url. The SSO login (state, PKCE verifier, nonce), the LTI login and
// the MCP OAuth server each used to write the same lines themselves.

import Foundation

/// 32 random bytes, base64url: unguessable, and safe in a URL, a cookie and a
/// session.
func randomURLSafeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64URLEncodedString()
}
