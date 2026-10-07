// APIServer/Services/DiskSpaceRule.swift
//
// The `diskSpaceLow` health rule: the file system that holds the server's data
// is nearly full. On 2026-10-07 old release images and predeploy snapshots
// filled the production disk. Postgres stopped, and login and both MCP surfaces
// failed. Nothing warned first: `databaseUnreachable` fires only once the site
// is already down. This rule fires while there is still time to act.
//
// The data volume, the Docker images and the deploy snapshots share one disk on
// the production host, so the free space this process sees is the free space
// that matters.

import Foundation
import Vapor

/// Free and total space on one file system, as `df` reports it: `freeBytes` is
/// the space available to an unprivileged writer.
struct DiskSpace: Codable, Sendable, Equatable {
    let freeBytes: Int
    let totalBytes: Int

    /// Free space as a fraction of the total, 0...1.
    var freeFraction: Double {
        totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0
    }

    /// "25.0 GB of 93.0 GB (27%)", for a place already labelled as free space.
    var freeOfTotalText: String {
        "\(humanReadableBytes(freeBytes)) of \(humanReadableBytes(totalBytes)) "
            + "(\(Int((freeFraction * 100).rounded()))%)"
    }

    /// "25.0 GB free of 93.0 GB (27%)".
    var summaryText: String {
        "\(humanReadableBytes(freeBytes)) free of \(humanReadableBytes(totalBytes)) "
            + "(\(Int((freeFraction * 100).rounded()))%)"
    }

    /// The file system that holds `path`, or nil when the path does not exist or
    /// the system does not report sizes.
    static func measure(atPath path: String) -> DiskSpace? {
        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
            let free = (attributes[.systemFreeSize] as? NSNumber)?.intValue,
            let total = (attributes[.systemSize] as? NSNumber)?.intValue,
            total > 0
        else { return nil }
        return DiskSpace(freeBytes: free, totalBytes: total)
    }
}

/// The rule fires when less than this fraction of the disk is free. On the
/// 93 GB production disk that is about 14 GB: several days of warning at the
/// rate the disk filled, and room for two release images.
///
/// A deliberate constant, per the standing rule against new environment
/// variables. Change it here.
let diskSpaceLowFreeFraction = 0.15

/// Decides the rule from one measurement. An unknown measurement does not fire:
/// a host that cannot report its disk has nothing to page about.
func decideDiskSpaceLow(
    _ space: DiskSpace?,
    threshold: Double = diskSpaceLowFreeFraction
) -> RuleEvaluation {
    guard let space else { return .ok }
    let details = [
        "free_bytes": String(space.freeBytes),
        "total_bytes": String(space.totalBytes),
        "free_percent": String(Int((space.freeFraction * 100).rounded())),
        "threshold_percent": String(Int((threshold * 100).rounded())),
    ]
    guard space.freeFraction < threshold else {
        return RuleEvaluation(isFiring: false, summary: "ok", details: details)
    }
    return RuleEvaluation(
        isFiring: true,
        summary:
            "Disk nearly full: \(space.summaryText). A full disk stops Postgres. "
            + "Check old release images and backups/ on the host.",
        details: details)
}

private struct DiskSpaceProbeKey: StorageKey {
    typealias Value = @Sendable (String) -> DiskSpace?
}

extension Application {
    /// How a path's disk is measured. Production reads the real file system.
    /// The test app replaces it, so that no test result depends on how full the
    /// disk of the machine that runs the tests is.
    var diskSpaceProbe: @Sendable (String) -> DiskSpace? {
        get { storage[DiskSpaceProbeKey.self] ?? { DiskSpace.measure(atPath: $0) } }
        set { storage[DiskSpaceProbeKey.self] = newValue }
    }

    /// The file system the rule watches: the one that holds submissions, which
    /// is the server's data volume.
    var diskSpaceOfDataVolume: DiskSpace? {
        diskSpaceProbe(submissionsDirectory)
    }
}

/// Measures the data volume and decides the rule. It reads no database, so it
/// still answers when a full disk has stopped Postgres.
func evaluateDiskSpaceLow(on application: Application) -> RuleEvaluation {
    decideDiskSpaceLow(application.diskSpaceOfDataVolume)
}
