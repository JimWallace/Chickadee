// APIServer/Utilities/DeployRequest.swift
//
// A request the admin page sends to the deploy daemon, and why writing one can
// fail (docs/release-gate.md, "The admin page asks; the daemon decides").

import Core
import Foundation

/// A request the admin page may send. These are the only four the daemon
/// accepts from the app.
enum DeployRequest: Sendable, Equatable {
    case approve(version: String)
    case mode(DeployMode)
    case pause
    case resume

    /// The JSON body, with the admin's username, which the daemon records.
    func body(user: String, requestedAt: Date) -> [String: String] {
        var fields = ["user": user, "requestedAt": iso8601String(requestedAt)]
        switch self {
        case .approve(let version):
            fields["request"] = "approve"
            fields["version"] = version
        case .mode(let mode):
            fields["request"] = "mode"
            fields["mode"] = mode.rawValue
        case .pause:
            fields["request"] = "pause"
        case .resume:
            fields["request"] = "resume"
        }
        return fields
    }
}

/// Why a request could not be written.
enum DeployRequestWriteError: Error, Equatable {
    /// The requests folder is not there: the daemon is not installed, or the
    /// container was started without the read-write requests mount.
    case requestsFolderMissing
    /// The folder is there, and the write failed (permissions, disk).
    case writeFailed
}
