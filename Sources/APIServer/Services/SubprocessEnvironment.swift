// APIServer/Services/SubprocessEnvironment.swift
//
// The one bridge from a `[String: String]` environment to swift-subprocess.

import Subprocess

extension Subprocess::Environment {
    /// Exactly `variables`, with nothing inherited from the server.
    ///
    /// Every child the server launches gets an explicit environment: the server
    /// holds secrets (the runner shared secret, database credentials, the OIDC
    /// client secret) that a child must see only when it is handed them.
    /// `Environment.Key` has no public non-failable initializer; the failable
    /// one never fails, so a skipped key is unreachable rather than a silent
    /// drop. The module selector is needed because `Environment` is also a
    /// Vapor type.
    static func only(_ variables: [String: String]) -> Self {
        var keyed: [Key: String] = [:]
        for (name, value) in variables {
            guard let key = Key(rawValue: name) else { continue }
            keyed[key] = value
        }
        return .custom(keyed)
    }
}
