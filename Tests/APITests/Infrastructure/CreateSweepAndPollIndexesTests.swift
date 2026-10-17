// Tests/APITests/Infrastructure/CreateSweepAndPollIndexesTests.swift

import Testing

@testable import APIServer

/// `CreateSweepAndPollIndexes` indexes every sweep and poll table that the
/// five issues behind it named, and nothing else.
@Suite struct CreateSweepAndPollIndexesTests {
    @Test func theListCoversEveryTableTheIssuesNamed() {
        let tables = Set(CreateSweepAndPollIndexes.indexes.map { $0.on.prefix { $0 != "(" } })
        #expect(
            tables == [
                "lti_grade_syncs", "match_results", "tournament_runs", "class_coverage_runs",
                "github_course_repositories", "lti_login_states", "lti_deep_link_requests",
            ])
    }
}
