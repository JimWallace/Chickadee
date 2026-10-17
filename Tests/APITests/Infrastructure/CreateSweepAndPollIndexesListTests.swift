import Testing

@testable import APIServer

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
