// Tests/APITests/ForwardingTestDatabase.swift
//
// The one forwarding Fluent `Database` for the API tests. It sends every
// query to a base database, except the queries its refusal rule names, which
// fail with `Refused`. It does not conform to `SQLDatabase`, so code under
// test that branches on `db as? any SQLDatabase` takes its store-agnostic
// path. A transaction or connection opened through it hands the closure a
// wrapped connection with the same rule, so a refusal (and a shared counter)
// reaches nested transactions too.

import Fluent
import NIOCore
import Synchronization

struct ForwardingTestDatabase: Database {
    /// The error a refused query fails with.
    struct Refused: Error {}

    let base: any Database
    let refuse: @Sendable (DatabaseQuery) -> Bool

    /// Forwards to `base`, failing each query for which `refuse` is true.
    /// With no rule, every query goes through.
    init(base: any Database, refuse: @escaping @Sendable (DatabaseQuery) -> Bool = { _ in false }) {
        self.base = base
        self.refuse = refuse
    }

    /// Fails every insert into `schema`.
    static func refusingInserts(into schema: String, base: any Database) -> ForwardingTestDatabase {
        ForwardingTestDatabase(base: base) { query in
            if query.schema == schema, case .create = query.action { return true }
            return false
        }
    }

    /// Fails the `number`th update (counting from 1) and only that one. The
    /// count is shared with every connection the wrapper hands out.
    static func failingUpdate(number: Int, base: any Database) -> ForwardingTestDatabase {
        let updates = UpdateCounter()
        return ForwardingTestDatabase(base: base) { query in
            guard case .update = query.action else { return false }
            return updates.next() == number
        }
    }

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        if refuse(query) { return base.eventLoop.makeFailedFuture(Refused()) }
        return base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let refuse = self.refuse
        return base.transaction { inner in closure(ForwardingTestDatabase(base: inner, refuse: refuse)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        let refuse = self.refuse
        return base.withConnection { inner in closure(ForwardingTestDatabase(base: inner, refuse: refuse)) }
    }
}

/// Counts updates across every connection one `failingUpdate` wrapper hands out.
private final class UpdateCounter: Sendable {
    private let count = Mutex(0)

    /// Records one update and returns how many there have been.
    func next() -> Int {
        count.withLock { value in
            value += 1
            return value
        }
    }
}
