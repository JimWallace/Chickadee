// APIServer/Auth/OIDCIDTokenRefusal.swift
//
// Why an ID token whose signature and expiry verified was still refused
// (OIDCIDTokenClaims.validate, OIDC Core 3.1.3.7).

enum OIDCIDTokenRefusal: Error, Equatable, Sendable {
    /// `iss` is not the issuer from the discovery document.
    case issuerMismatch
    /// `aud` does not contain this client's ID.
    case audienceMismatch
    /// `azp` is present and names another client.
    case authorizedPartyMismatch
    /// `aud` names several clients and `azp` is absent.
    case authorizedPartyMissing
    /// `iat` is later than now plus the allowed clock skew.
    case issuedInFuture
    /// `nonce` is absent or differs from the one this login sent.
    case nonceMismatch
}
