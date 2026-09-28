// APIServer/Models/APIClassCoverageRun.swift
//
// One synthetic corpus run: the class's contributed slot cells assembled into
// a single notebook, graded once, and the coverage number that grade produced
// (docs/collaborative-class-assignments.md, Phase 4).
//
// ONE ROW PER RUN, not per assignment. A run is opened at enqueue with no
// coverage and completed at ingest, so the row is the only place that knows a
// corpus run is in flight — which is what the debounce reads. Keeping the
// earlier completed rows means the live number never disappears while the next
// run is queued: readers take the newest COMPLETED row, so an in-flight run
// cannot blank a progress bar that freezes into a grade push.
//
// IT STORES WHO CONTRIBUTED, as a JSON array of user ids — the
// `tournament_runs` entrant-snapshot shape. The cheaper alternative was to
// recompute the set at read time as "every student with a complete submission",
// and that is not the same set: a student who submits and writes nothing in any
// slot contributes no cell but would still count toward BREADTH, inflating a
// number that carries bonus points to the LMS. That is audit A7's shape
// exactly, so the set is captured when the corpus is assembled and read back
// verbatim.
//
// It is a second copy of who contributed, which the Phase 4 note warns about,
// so `deleteCourse` reaches these rows explicitly. It holds ids and nothing a
// student wrote; the contributions themselves live only in the corpus
// notebook, which is an ordinary submission file and is deleted with the rest.

import Fluent
import Vapor

final class APIClassCoverageRun: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: rows are created and completed on one request's
    // database handle, never shared across concurrent tasks.
    static let schema = "class_coverage_runs"

    @ID(key: .id)
    var id: UUID?

    /// The assignment (test setup) whose class corpus this run graded.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The `kind == .classAggregate` submission carrying the assembled corpus.
    @Field(key: "submission_id")
    var submissionID: String

    /// The students whose slot cells went into the corpus, as a JSON array of
    /// uuid strings. Read back by the sweep and intersected with the CURRENT
    /// roster for the breadth half of a coverage goal — the same split the
    /// union goal carries, where the coverage number counts what was produced
    /// and breadth counts who is still here.
    @Field(key: "contributors")
    var contributorsJSON: String

    /// Fraction of the reference the corpus covered, `0...1` — the run's own
    /// grade. nil until the result lands, and left nil when the run failed to
    /// build: a corpus that could not compile covers nothing *yet*, which is
    /// not the same as covering nothing.
    @OptionalField(key: "coverage")
    var coverage: Double?

    /// When the corpus was assembled and enqueued. Also the cutoff that says
    /// which submissions it was built from.
    @Field(key: "created_at")
    var createdAt: Date

    /// When the run's result landed; nil while it is in flight.
    @OptionalField(key: "completed_at")
    var completedAt: Date?

    init() {}

    init(
        testSetupID: String,
        submissionID: String,
        contributors: [UUID],
        createdAt: Date = Date()
    ) {
        self.testSetupID = testSetupID
        self.submissionID = submissionID
        self.contributorsJSON = Self.encode(contributors)
        self.coverage = nil
        self.createdAt = createdAt
        self.completedAt = nil
    }

    /// The contributor ids this run was assembled from. An unreadable column
    /// decodes as none, which reads as "nobody contributed" and holds breadth
    /// at zero — the direction that withholds a bonus rather than granting an
    /// unearned one.
    var contributors: [UUID] {
        guard let data = contributorsJSON.data(using: .utf8),
            let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return raw.compactMap(UUID.init(uuidString:))
    }

    /// Sorted so the stored bytes are a function of the set alone: a corpus
    /// assembled from the same students twice writes the same column.
    static func encode(_ contributors: [UUID]) -> String {
        let sorted = contributors.map(\.uuidString).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
            let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }
}
