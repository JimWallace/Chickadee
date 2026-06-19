// APIServer/Models/APIBrightSpaceCredential.swift
//
// Persisted D2L Valence USER key/id captured via the admin "Authorize
// BrightSpace" flow (AdminRoutes+BrightSpace). This is the durable counterpart
// to BRIGHTSPACE_USER_ID/KEY in env: it lets an admin re-authorize the
// deployment's service identity from the UI without an env change + restart.
//
// One active row (single service-account identity). `BrightSpaceCredentialStore`
// keeps only the most recent — saving replaces any prior row. The app creds
// (URL/App ID/App Key) stay env-only and are NOT stored here.
//
// SECURITY: `valence_user_key` is a usable long-lived credential, stored in
// cleartext (consistent with the `.worker-secret` precedent). It can act as the
// service account in LEARN, so DB-at-rest access controls are the protection;
// rotating/revoking the key in D2L invalidates it. Future work: encrypt at rest
// behind an env-supplied key.

import Fluent
import Vapor

final class APIBrightSpaceCredential: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "brightspace_credentials"

    @ID(key: .id)
    var id: UUID?

    /// The Valence user id (`x_a` from the handshake) — the D2L account the
    /// service keys act as.
    @Field(key: "valence_user_id")
    var valenceUserID: String

    /// The Valence user key (`x_b`) — the per-account signing secret.
    @Field(key: "valence_user_key")
    var valenceUserKey: String

    /// `whoami` display name captured at authorize time, shown in the admin UI
    /// so the admin can confirm which account they authorized.
    @OptionalField(key: "identity_name")
    var identityName: String?

    /// The admin who performed the authorization (audit).
    @OptionalField(key: "captured_by_user_id")
    var capturedByUserID: UUID?

    @Timestamp(key: "captured_at", on: .create)
    var capturedAt: Date?

    init() {}

    init(
        valenceUserID: String,
        valenceUserKey: String,
        identityName: String?,
        capturedByUserID: UUID?
    ) {
        self.valenceUserID = valenceUserID
        self.valenceUserKey = valenceUserKey
        self.identityName = identityName
        self.capturedByUserID = capturedByUserID
    }
}
