// APIServer/Services/BackgroundWork.swift
//
// The owner of the work the server starts and does not wait for (#1923): a
// "Sync now" grade push, the IdP token revocation at logout, and the OIDC
// discovery fetch at boot. Each of these was a bare `Task { }` that nothing
// kept, so it could outlive the application. The grade push reads and writes
// `application.db`, and a query after Fluent closes the database fails, and a
// second read of `app.db` on the failure path traps in Fluent's accessor
// (#1700). `DataExportManager` fixed that shape for export generation; this is
// the same owner without the per-user key.

import Vapor

/// Keeps every task it starts until the task ends, and cancels and awaits them
/// all at shutdown.
actor BackgroundWork {
    private var running: [UUID: Task<Void, Never>] = [:]
    private var isDraining = false

    /// Runs `work` on a task this owner keeps until it ends. Returns false, and
    /// runs nothing, once `drain()` has begun: work started then would outlive
    /// the drain, which is the defect this type exists to close.
    @discardableResult
    func start(_ work: @escaping @Sendable () async -> Void) -> Bool {
        guard !isDraining else { return false }
        let id = UUID()
        running[id] = Task {
            await work()
            finished(id)
        }
        return true
    }

    /// How many started tasks have not ended yet.
    var runningCount: Int { running.count }

    /// Cancels every running task and waits for each to end. Work that checks
    /// for cancellation stops at its next check; other work runs to its end.
    func drain() async {
        isDraining = true
        let tasks = Array(running.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    private func finished(_ id: UUID) {
        running[id] = nil
    }
}

/// Drains `Application.backgroundWork` at shutdown.
///
/// Vapor runs `shutdownAsync` handlers in reverse registration order, and
/// Fluent registers its handler when the database is configured, before
/// `bootstrapAppServices` registers this one. So the drain runs while `app.db`
/// is still open.
struct BackgroundWorkDrainLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.backgroundWork.drain()
    }
}

struct BackgroundWorkKey: StorageKey {
    typealias Value = BackgroundWork
}

extension Application {
    /// Set once at boot by `bootstrapAppServices`, before any request can race
    /// to create it: the lazy accessor is not synchronised, and a second owner
    /// would never be drained.
    var backgroundWork: BackgroundWork {
        get { lazyStored(BackgroundWorkKey.self) { BackgroundWork() } }
        set { storage[BackgroundWorkKey.self] = newValue }
    }
}
