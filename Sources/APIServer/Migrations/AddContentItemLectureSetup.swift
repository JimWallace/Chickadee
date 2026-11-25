// APIServer/Migrations/AddContentItemLectureSetup.swift
//
// `course_content_items.lecture_test_setup_id`: the test setup that holds a
// lecture notebook (docs/lecture-notebooks.md). Nil for every other item. The
// setup has no `assignments` row, which is what keeps a lecture out of grading.
//
// Nullable, so the running version keeps reading the table during a blue-green
// deploy. The foreign key sets the column to NULL if the setup row is deleted
// (a course purge deletes setups by course). The unique constraint holds "one
// item per lecture setup" and is the key's leading index.

import Fluent

struct AddContentItemLectureSetup: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("course_content_items")
            .field(
                "lecture_test_setup_id",
                .string,
                .references("test_setups", "id", onDelete: .setNull)
            )
            .unique(on: "lecture_test_setup_id", name: "uq_course_content_items_lecture_test_setup_id")
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("course_content_items")
            .deleteConstraint(name: "uq_course_content_items_lecture_test_setup_id")
            .deleteField("lecture_test_setup_id")
            .update()
    }
}
