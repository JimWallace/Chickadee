// APIServer/MCP/Admin/Tools/GetDeploymentInfoTool.swift
//
// Read tool: report the deployed server's version and diagnostic-surface
// capability. The admin analog of the content surface's get_server_info, and the
// first tool that proves the admin dispatch pipeline end to end.
//
// Deliberately DB-free: returns static server metadata and the newest cached
// database-configuration reading (`DatabaseProfileService`, taken at boot and
// refreshed by the admin Overview), so it stays a useful liveness check even
// when the database is unavailable (which is itself a thing an operator wants
// to diagnose). No student or course state, and no credential, host or role
// name.

import Core
import Vapor

struct GetDeploymentInfoTool: DiagnosticTool {
    struct Input: Decodable, Sendable {}

    struct Output: Encodable, Sendable {
        /// The deployed Chickadee version (`ChickadeeVersion.current`).
        let version: String
        /// The Vapor environment name (e.g. "production", "development").
        let environment: String
        /// The active admin-MCP mode ("read_only"; the endpoint is unmounted in
        /// "off", so a reachable call is never that).
        let adminMcpMode: String
        /// Scopes the admin surface advertises and honors, in stable order.
        let advertisedScopes: [String]
        /// The content-authoring MCP mode ("off" / "read_only" / "read_write"),
        /// a capability probe of the other surface.
        let contentMcpMode: String
        /// The database configuration as last read, or nil before the first
        /// reading.
        let database: DatabaseReading?
    }

    /// The database configuration as last read. Every key is always present;
    /// null is a read that failed.
    struct DatabaseReading: Encodable, Sendable {
        let serverVersion: String?
        let majorVersion: Int?
        let dataChecksums: Bool?
        let maxConnections: Int?
        let statStatementsLoaded: Bool?
        let serverEncoding: String?
        let collation: String?
        let sizeBytes: Int?
        let mcpPoolConfigured: Bool
        let mcpPoolSeparateRole: Bool?
        /// When the stored configuration was first seen (ISO 8601).
        let since: String?
        /// The values that differ from the configuration before it.
        let previous: [Change]
        /// When this reading was taken (ISO 8601).
        let observedAt: String

        struct Change: Encodable, Sendable {
            let field: String
            let previous: String
            let current: String
        }

        init(_ snapshot: DatabaseProfileSnapshot) {
            serverVersion = snapshot.serverVersion
            majorVersion = snapshot.majorVersion
            dataChecksums = snapshot.dataChecksums
            maxConnections = snapshot.maxConnections
            statStatementsLoaded = snapshot.statStatementsLoaded
            serverEncoding = snapshot.serverEncoding
            collation = snapshot.collation
            sizeBytes = snapshot.sizeBytes
            mcpPoolConfigured = snapshot.mcpPool.isConfigured
            mcpPoolSeparateRole = snapshot.mcpPool.isSeparateRole
            since = snapshot.since.map(iso8601String)
            previous = snapshot.previousChanges.map { Change(field: $0.key, previous: $0.old, current: $0.new) }
            observedAt = iso8601String(snapshot.observedAt)
        }

        private enum CodingKeys: String, CodingKey {
            case serverVersion, majorVersion, dataChecksums, maxConnections, statStatementsLoaded
            case serverEncoding, collation, sizeBytes, mcpPoolConfigured, mcpPoolSeparateRole
            case since, previous, observedAt
        }

        /// Encodes a nil as an explicit null, so every key is present.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(serverVersion, forKey: .serverVersion)
            try container.encode(majorVersion, forKey: .majorVersion)
            try container.encode(dataChecksums, forKey: .dataChecksums)
            try container.encode(maxConnections, forKey: .maxConnections)
            try container.encode(statStatementsLoaded, forKey: .statStatementsLoaded)
            try container.encode(serverEncoding, forKey: .serverEncoding)
            try container.encode(collation, forKey: .collation)
            try container.encode(sizeBytes, forKey: .sizeBytes)
            try container.encode(mcpPoolConfigured, forKey: .mcpPoolConfigured)
            try container.encode(mcpPoolSeparateRole, forKey: .mcpPoolSeparateRole)
            try container.encode(since, forKey: .since)
            try container.encode(previous, forKey: .previous)
            try container.encode(observedAt, forKey: .observedAt)
        }

        /// The schema of one `database` value.
        static let schema: JSONValue = MCPSchema.object(
            properties: [
                "serverVersion": MCPSchema.nullableString,
                "majorVersion": MCPSchema.nullableInteger,
                "dataChecksums": nullableBoolean,
                "maxConnections": MCPSchema.nullableInteger,
                "statStatementsLoaded": nullableBoolean,
                "serverEncoding": MCPSchema.nullableString,
                "collation": MCPSchema.nullableString,
                "sizeBytes": MCPSchema.nullableInteger,
                "mcpPoolConfigured": MCPSchema.boolean,
                "mcpPoolSeparateRole": nullableBoolean,
                "since": MCPSchema.nullableString,
                "previous": .object([
                    "type": .string("array"),
                    "items": MCPSchema.object(
                        properties: [
                            "field": MCPSchema.string, "previous": MCPSchema.string, "current": MCPSchema.string,
                        ],
                        required: ["field", "previous", "current"], additionalProperties: nil),
                ]),
                "observedAt": MCPSchema.string,
            ],
            required: [
                "serverVersion", "majorVersion", "dataChecksums", "maxConnections", "statStatementsLoaded",
                "serverEncoding", "collation", "sizeBytes", "mcpPoolConfigured", "mcpPoolSeparateRole",
                "since", "previous", "observedAt",
            ],
            additionalProperties: nil)

        private static let nullableBoolean: JSONValue = .object([
            "type": .array([.string("boolean"), .string("null")])
        ])
    }

    static let name = "get_deployment_info"
    static let description =
        "Report the deployed server's version and capability surface: the Chickadee version, the "
        + "Vapor environment, the admin diagnostic MCP mode and its advertised scopes, and the "
        + "content-authoring MCP mode, and the database configuration as last read (PostgreSQL version "
        + "and major, data checksums, max_connections, pg_stat_statements, encoding, collation, size, "
        + "whether the MCP pool connects as its own role, since when, and what it was before; a null "
        + "is a read that failed). Use it to confirm a deploy or a database upgrade is live (a tool "
        + "call hits the running process, unlike a cached tool list). Read-only and database-free: "
        + "the database reading is the one cached at boot or by the admin Overview, as of observedAt. "
        + "No course or student data, and no credential, host or role name."
    static let inputSchema: JSONValue = MCPSchema.noArgumentsInput
    /// The admin re-check reads the users table, and this tool must answer
    /// when the database is down. The bearer layer still gates it.
    static let rechecksAdminRole = false
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "version": MCPSchema.string,
            "environment": MCPSchema.string,
            "adminMcpMode": MCPSchema.string,
            "advertisedScopes": .object([
                "type": .string("array"), "items": MCPSchema.string,
            ]),
            "contentMcpMode": MCPSchema.string,
            "database": DatabaseReading.schema,
        ]),
        "required": .array([
            .string("version"), .string("environment"), .string("adminMcpMode"),
            .string("advertisedScopes"), .string("contentMcpMode"),
        ]),
    ])

    func execute(_ input: Input, _ context: AdminToolContext) async throws -> Output {
        let config = context.request.application.appConfig
        // The admin surface is tied to MCP_MODE (all-or-nothing) and is always
        // read-only — even under MCP_MODE=read_write it reports read_only and
        // advertises only diagnostics:read.
        let adminMounted = config.mcp.mode.isMounted
        return Output(
            version: ChickadeeVersion.current,
            environment: context.request.application.environment.name,
            adminMcpMode: adminMounted ? "read_only" : "off",
            advertisedScopes: adminMounted ? adminMCPAdvertisedScopes.map(\.rawValue) : [],
            contentMcpMode: config.mcp.mode.rawValue,
            database: await DatabaseProfileService.latestSnapshot(app: context.request.application).map(
                DatabaseReading.init))
    }
}
