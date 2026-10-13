import Testing

@testable import chickadee_loadtest

/// `parse` runs `validate()`, so a refused option set throws here, before
/// any request goes out.
@Suite struct LoadTestCommandTests {
    @Test func defaultsAreValid() throws {
        let command = try LoadTestCommand.parse([])
        #expect(command.baseURL == "http://localhost:8080")
        #expect(command.runners == 10)
        #expect(command.statusPollers == 0)
        #expect(!command.allowRemote)
    }

    @Test func statusPollsWithTheirInputsAreValid() throws {
        let command = try LoadTestCommand.parse([
            "--runners", "0", "--status-pollers", "5",
            "--submission-id", "sub_1", "--session-cookie", "vapor-session=abc",
        ])
        #expect(command.statusPollers == 5)
        #expect(command.submissionID == "sub_1")
    }

    @Test(arguments: [
        ["--duration", "0"],
        ["--runners", "-1"],
        ["--runners", "0", "--status-pollers", "0"],
        ["--runner-poll-interval", "0"],
        ["--status-poll-interval", "-2"],
        ["--status-pollers", "3"],
        ["--status-pollers", "3", "--submission-id", "sub_1"],
        ["--status-pollers", "3", "--session-cookie", "vapor-session=abc"],
    ])
    func invalidOptionsAreRefused(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try LoadTestCommand.parse(arguments)
        }
    }
}
