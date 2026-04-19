import Fluent
import Foundation
import SQLKit

private final class AssignmentSlugBackfillRow: Model, @unchecked Sendable {
    static let schema = "assignments"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "title")
    var title: String

    @OptionalField(key: "slug")
    var slug: String?

    @Field(key: "course_id")
    var courseID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}
}

struct AddAssignmentSlugs: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("slug", .string)
            .update()

        let assignments = try await AssignmentSlugBackfillRow.query(on: database).all()
        var usedByCourse: [UUID: Set<String>] = [:]
        let sorted = assignments.sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }

        for assignment in sorted {
            let slug = try await uniqueAssignmentSlug(
                title: assignment.title,
                courseID: assignment.courseID,
                excludingAssignmentID: try? assignment.requireID(),
                db: database,
                reserved: usedByCourse[assignment.courseID] ?? []
            )
            assignment.slug = slug
            usedByCourse[assignment.courseID, default: []].insert(slug)
            try await assignment.save(on: database)
        }

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE UNIQUE INDEX idx_assignments_course_slug ON assignments (course_id, slug)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_assignments_course_slug").run()
        }
        try await database.schema("assignments")
            .deleteField("slug")
            .update()
    }
}
