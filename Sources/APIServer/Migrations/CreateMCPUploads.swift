import Fluent
import SQLKit

/// Staged MCP file uploads (docs/mcp-file-uploads.md). The unique
/// `token_hash` matches the PUT's token; the `expires_at` index backs
/// the purge of unused rows, and the `course_id` index the course-delete
/// cascade.
struct CreateMCPUploads: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(MCPUpload.schema)
            .id()
            .field("token_hash", .string, .required)
            .field("subject", .string, .required)
            .field("client_id", .string)
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("bytes", .data)
            .field("sha256", .string)
            .field("uploaded_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()

        if let sql = database as? (any SQLDatabase) {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_mcp_uploads_expires_at ON mcp_uploads(expires_at)"
            ).run()
            // Backs the cascade when a course is deleted.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_mcp_uploads_course_id ON mcp_uploads(course_id)"
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MCPUpload.schema).delete()
    }
}
