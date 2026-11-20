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

    /// A request read back from a file the app wrote and the daemon has not
    /// read yet, or nil for a body that names none of the four.
    init?(body: [String: String]) {
        switch body["request"] {
        case "approve":
            guard let version = body["version"] else { return nil }
            self = .approve(version: version)
        case "mode":
            guard let mode = body["mode"].flatMap(DeployMode.init(rawValue:)) else { return nil }
            self = .mode(mode)
        case "pause": self = .pause
        case "resume": self = .resume
        default: return nil
        }
    }

    /// The mode the last waiting mode request asks for, or nil when none
    /// waits. The daemon reads requests oldest first, so the last one wins.
    static func lastMode(in waiting: [DeployRequest]) -> DeployMode? {
        waiting.compactMap { request -> DeployMode? in
            if case .mode(let mode) = request { mode } else { nil }
        }.last
    }

    /// Why sending `self` would add nothing, given the requests still
    /// waiting and the mode in force, or nil when it should be sent. A mode,
    /// pause or resume repeats the last waiting request of its kind; an
    /// approval repeats any waiting approval of the same version.
    func redundancy(waiting: [DeployRequest], modeInForce: DeployMode) -> DeployRequestRedundancy? {
        switch self {
        case .approve:
            return waiting.contains(self) ? .alreadyWaiting : nil
        case .mode(let mode):
            if let last = Self.lastMode(in: waiting) {
                return last == mode ? .alreadyWaiting : nil
            }
            return mode == modeInForce ? .alreadyInForce : nil
        case .pause, .resume:
            return waiting.last(where: { $0 == .pause || $0 == .resume }) == self ? .alreadyWaiting : nil
        }
    }

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

/// Why a request is not sent: it would only repeat what is already asked.
enum DeployRequestRedundancy: Sendable, Equatable {
    /// The same request waits for the daemon's next poll.
    case alreadyWaiting
    /// A mode change to the mode in force, with no other mode change waiting.
    case alreadyInForce
}

/// Why a request could not be written.
enum DeployRequestWriteError: Error, Equatable {
    /// The requests folder is not there: the daemon is not installed, or the
    /// container was started without the read-write requests mount.
    case requestsFolderMissing
    /// The folder is there, and the write failed (permissions, disk).
    case writeFailed
}
