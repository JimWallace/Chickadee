// APIServer/Utilities/Base64URL.swift
//
// Shared base64url (RFC 4648 §5) encoding used by the OAuth/PKCE flows, the
// ES256 JWT minting in MCPTokenAuthority, and the BrightSpace HMAC signing.
// Previously each site reimplemented the same `+`→`-`, `/`→`_`, strip-`=`
// transform; this is the single source so they cannot drift.

import Foundation

extension Data {
    /// Base64url encoding: standard base64 with `+`→`-`, `/`→`_`, and padding
    /// (`=`) removed.
    func base64URLEncodedString() -> String {
        base64EncodedString().base64ToBase64URL()
    }
}

extension String {
    /// Converts a standard base64 string to unpadded base64url.
    func base64ToBase64URL() -> String {
        replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
