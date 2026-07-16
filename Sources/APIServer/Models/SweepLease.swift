import Fluent
import Foundation
import Vapor

/// One leader lease per periodic sweep (#1155). `PeriodicSweepMonitor` runs
/// on every server process, so without coordination a multi-process
/// deployment runs every sweep N times — duplicate BrightSpace grade pushes,
/// double health alerts, racing reapers. Each sweep tick claims/renews the
/// lease row for its sweep name with an atomic conditional UPDATE; only the
/// holder runs the sweep body. A crashed leader stops renewing and the lease
/// expires, so another instance takes over within one TTL.
final class SweepLease: Model, @unchecked Sendable {
    // @unchecked Sendable: written only through SweepLeaseCoordinator's
    // conditional queries, never mutated concurrently in-process.
    static let schema = "sweep_leases"

    @ID(custom: "name", generatedBy: .user)
    var id: String?

    @Field(key: "holder")
    var holder: String

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(name: String, holder: String, expiresAt: Date) {
        self.id = name
        self.holder = holder
        self.expiresAt = expiresAt
    }
}
