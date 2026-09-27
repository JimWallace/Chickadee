// APIServer/LTI/LTILaunchSecrets.swift
//
// The random values an LTI login mints (`state`, `nonce`) and the hash the
// database stores in place of `state`.

import Crypto
import Foundation

enum LTILaunchSecrets {
    /// 32 random bytes, base64url: unguessable, and safe in a URL and a cookie.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }

    /// SHA-256, base64url. What `lti_login_states.state_hash` holds.
    static func hash(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64URLEncodedString()
    }
}
