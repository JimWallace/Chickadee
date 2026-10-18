// Tests/APITests/MCP/MCPRoleDatabase.swift
//
// A stand-in for the least-privilege `chickadee_mcp` role, so a test can run a
// real MCP tool with the dedicated MCP pool configured. The test databases have
// no roles: every query succeeds on them, so a tool that queries a table the
// role cannot use passes every test and fails only in production.
//
// The stand-in forwards each query to the test's own database and refuses the
// ones the role would refuse:
// - A query on a table without the privilege it needs, read from
//   deploy/sql/mcp-least-privilege-role.sql through `MCPRoleGrants`.
// - Any schema or enum change.
// It also hides what the row-level security policy on `submissions` hides: any
// row whose kind is not `validation`.
//
// Where it differs from the real role:
// - It hides rows after the database applies `sort` and `limit`; RLS hides
//   them first. A `submissions` query with no kind filter can find nothing
//   here and a validation row in production.
// - An aggregate on `submissions`, such as `count()`, returns no row here,
//   because its output has no `kind`.
// - The RLS policies on `results`, `result_collections`,
//   `validation_variants` and `reflection_feedback`, and the gated
//   AI-feedback policy on `submissions`, are not modelled.
// - Postgres also needs SELECT for an UPDATE or DELETE with a filter; this
//   checks only the UPDATE or DELETE privilege.

import Fluent
import FluentKit
import Foundation
import Vapor

@testable import APIServer

struct MCPRoleDatabase: Database {
    struct PermissionDenied: Error, CustomStringConvertible {
        let table: String
        let privilege: String
        var description: String { "permission denied for table \(table) (needs \(privilege))" }
    }

    struct SchemaChangeDenied: Error {}

    struct NoDefaultDatabase: Error {}

    let context: DatabaseContext
    let inTransaction: Bool
    let grants: [String: Set<String>]
    /// The owner database under the stand-in. A closure, because the driver
    /// cannot look it up while `Databases` holds its lock.
    private let base: @Sendable () -> (any Database)?

    init(context: DatabaseContext, grants: [String: Set<String>], base: @escaping @Sendable () -> (any Database)?) {
        self.context = context
        self.inTransaction = false
        self.grants = grants
        self.base = base
    }

    private init(inside base: any Database, grants: [String: Set<String>]) {
        self.context = base.context
        self.inTransaction = base.inTransaction
        self.grants = grants
        self.base = { base }
    }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        // The queried table needs the action's privilege; a joined one is
        // only read.
        let needed =
            [(query.schema, Self.privilege(for: query.action))]
            + query.joins.compactMap(Self.schema(of:)).map { ($0, "SELECT") }
        for (table, privilege) in needed where grants[table]?.contains(privilege) != true {
            return eventLoop.makeFailedFuture(PermissionDenied(table: table, privilege: privilege))
        }
        guard let base = base() else { return eventLoop.makeFailedFuture(NoDefaultDatabase()) }
        guard query.schema == APISubmission.schema else {
            return base.execute(query: query, onOutput: onOutput)
        }
        return base.execute(query: query) { output in
            let kind = try? output.schema(APISubmission.schema).decode("kind", as: String.self)
            if kind == APISubmission.Kind.validation {
                onOutput(output)
            }
        }
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(SchemaChangeDenied())
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(SchemaChangeDenied())
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard let base = base() else { return eventLoop.makeFailedFuture(NoDefaultDatabase()) }
        let grants = grants
        return base.transaction { closure(MCPRoleDatabase(inside: $0, grants: grants)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard let base = base() else { return eventLoop.makeFailedFuture(NoDefaultDatabase()) }
        let grants = grants
        return base.withConnection { closure(MCPRoleDatabase(inside: $0, grants: grants)) }
    }

    private static func privilege(for action: DatabaseQuery.Action) -> String {
        switch action {
        case .read, .aggregate: "SELECT"
        case .create: "INSERT"
        case .update: "UPDATE"
        case .delete: "DELETE"
        case .custom: "CUSTOM"
        }
    }

    private static func schema(of join: DatabaseQuery.Join) -> String? {
        switch join {
        case .join(let schema, _, _, _, _), .extendedJoin(let schema, _, _, _, _, _),
            .advancedJoin(let schema, _, _, _, _):
            schema
        case .custom:
            nil
        }
    }
}

extension Application {
    /// Configures the dedicated MCP pool as `MCPRoleDatabase` over this app's
    /// default database, as `MCP_DATABASE_USER` does in production. After
    /// this, `ToolContext.db` behaves like the `chickadee_mcp` role and
    /// `ToolContext.mainDB` stays the owner pool.
    func useMCPRoleDatabase() throws {
        databases.use(
            MCPRoleDatabaseConfiguration(grants: try MCPRoleGrants.privilegesByTable()), as: .mcp, isDefault: false)
        usesDedicatedMCPDatabase = true
    }
}

private struct MCPRoleDatabaseConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    let grants: [String: Set<String>]

    func makeDriver(for databases: Databases) -> any DatabaseDriver {
        Driver(databases: databases, grants: grants)
    }

    struct Driver: DatabaseDriver {
        unowned let databases: Databases
        let grants: [String: Set<String>]

        func makeDatabase(with context: DatabaseContext) -> any Database {
            let databases = databases
            return MCPRoleDatabase(context: context, grants: grants) {
                databases.database(logger: context.logger, on: context.eventLoop)
            }
        }

        func shutdown() {}
    }
}
