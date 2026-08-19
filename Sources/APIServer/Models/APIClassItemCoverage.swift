// APIServer/Models/APIClassItemCoverage.swift
//
// One row per (assignment, item) the class has collectively covered, attributed
// to the submission that covered it FIRST.
//
// This is the durable union behind a collaborative assignment's class-wide goal
// — "the class has found 9 of the 15 seeded bugs". The per-test outcomes it is
// derived from already exist in `result_collections`, so nothing here is new
// information; what is new is that the union is materialised, attributed and
// cheap to read.
//
// WHY IT IS WRITTEN AT INGEST RATHER THAN FOLDED IN THE SWEEP. The class-goal
// sweep is deliberately blob-free (#1160): it reads grade summaries and never
// the stored collection JSON, because it runs on a timer over every
// goal-bearing assignment forever. Unioning per-outcome data there would mean
// decoding every submission's collection every five minutes for the whole term.
// Accumulating one row at result time costs a single insert on a path that has
// already decoded the collection anyway.
//
// FIRST-FINDER WINS, ENFORCED BY THE SCHEMA. The unique constraint on
// (test_setup_id, item) is what makes this monotone and idempotent rather than
// merely intended: a re-test, a replayed report, or two students covering the
// same item concurrently all collapse to the row that landed first. The class
// number can therefore never go down — which matters because it drives a
// visible progress bar that freezes into a grade push.

import Fluent
import Vapor

final class APIClassItemCoverage: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "class_item_coverage"

    @ID(key: .id)
    var id: UUID?

    /// The assignment this coverage belongs to.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The covered item — the runner-stamped test name of the suite entry that
    /// passed. For a seeded-bug assignment that is one buggy variant; the
    /// instructor's driver decides what passing means.
    @Field(key: "item")
    var item: String

    /// The student whose submission covered it first.
    @Field(key: "user_id")
    var userID: UUID

    /// The specific submission that covered it first. Attribution is what makes
    /// the aggregate auditable — an instructor can see who found each item.
    @Field(key: "submission_id")
    var submissionID: String

    @Timestamp(key: "covered_at", on: .create)
    var coveredAt: Date?

    init() {}

    init(testSetupID: String, item: String, userID: UUID, submissionID: String) {
        self.testSetupID = testSetupID
        self.item = item
        self.userID = userID
        self.submissionID = submissionID
    }
}
