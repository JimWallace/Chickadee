// APIServer/LTI/LTIPlatformRegistration.swift
//
// The registration facts a launch is checked against, as a value type so
// `LTILaunchValidator` stays pure and testable without a database.

import Foundation

struct LTIPlatformRegistration: Sendable, Equatable {
    /// The platform's `iss` value.
    let issuer: String
    /// The client ID the platform issued to Chickadee.
    let clientID: String
    /// The deployment IDs Chickadee accepts from this registration.
    let deploymentIDs: Set<String>
}
