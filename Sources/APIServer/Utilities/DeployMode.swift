// APIServer/Utilities/DeployMode.swift
//
// The deploy modes the admin page sets and the deploy daemon reads
// (docs/release-gate.md).

import Foundation

/// One deploy mode. The raw value is what the daemon reads from its `mode` file.
enum DeployMode: String, CaseIterable, Sendable {
    case autonomous
    case gatedMinors = "gated-minors"
    case manual

    /// The mode the daemon uses when its `mode` file is absent.
    static let daemonDefault: DeployMode = .gatedMinors

    var label: String {
        switch self {
        case .autonomous: "Autonomous"
        case .gatedMinors: "Gated minors"
        case .manual: "Manual"
        }
    }

    /// What deploys on its own in this mode. A major always waits.
    var summary: String {
        switch self {
        case .autonomous: "Patches and minors deploy on their own; a major waits."
        case .gatedMinors: "Patches deploy on their own; a minor or a major waits."
        case .manual: "Every release waits for approval."
        }
    }
}
