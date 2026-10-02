import Fluent
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

/// The index-only migration creates every index it lists.
///
/// Pinned because an index is invisible to every other test: dropping a
/// `CREATE INDEX` changes no answer, only the cost of getting it, so nothing
/// else would go red.
@Suite(.serialized) final class CreateSweepAndPollIndexesTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp()
    }

    @Test func everyListedIndexExists() async throws {
        try await withApp(app) { app in
            let sql = try #require(app.db as? SQLDatabase)
            let names = try await Self.indexNames(on: sql)
            for index in CreateSweepAndPollIndexes.indexes {
                #expect(names.contains(index.name), "\(index.name) was not created")
            }
        }
    }

    /// Every index name the database knows, on either dialect the test
    /// lanes run.
    private static func indexNames(on sql: SQLDatabase) async throws -> Set<String> {
        let query: SQLQueryString =
            sql.dialect.name == "postgresql"
            ? "SELECT indexname AS name FROM pg_indexes"
            : "SELECT name FROM sqlite_master WHERE type = 'index'"
        let rows = try await sql.raw(query).all()
        return Set(try rows.map { try $0.decode(column: "name", as: String.self) })
    }
}

/// The list names every table the five issues named, and nothing else.
@Suite struct CreateSweepAndPollIndexesListTests {
    @Test func theListCoversEveryTableTheIssuesNamed() {
        let tables = Set(CreateSweepAndPollIndexes.indexes.map { $0.on.prefix { $0 != "(" } })
        #expect(
            tables == [
                "lti_grade_syncs", "match_results", "tournament_runs", "class_coverage_runs",
                "github_course_repositories", "lti_login_states", "lti_deep_link_requests",
            ])
    }
}
