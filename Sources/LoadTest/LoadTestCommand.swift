// LoadTest/LoadTestCommand.swift
//
// The chickadee-loadtest CLI. It simulates deadline traffic on the server's
// hot paths (runner polls and result-view status polls) for a fixed time,
// then prints the latency each stream saw. See docs/load-testing.md.

import ArgumentParser
import AsyncHTTPClient
import Core
import Foundation

@main
struct LoadTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chickadee-loadtest",
        abstract: "Simulate deadline traffic on the server's hot paths and report the latency",
        version: ChickadeeVersion.current
    )

    @Option(name: .long, help: "Base URL of the server to load")
    var baseURL: String = "http://localhost:8080"

    @Flag(name: .long, help: "Allow a server that is not on this machine. Never point this at production")
    var allowRemote: Bool = false

    @Option(name: .long, help: "How long to run, in seconds")
    var duration: Int = 60

    @Option(name: .long, help: "Number of simulated runner slots that poll for jobs")
    var runners: Int = 10

    @Option(name: .long, help: "Seconds between the polls of one runner slot")
    var runnerPollInterval: Double = 1

    @Option(name: .long, help: "File that holds the runner shared secret: the .worker-secret file the server writes")
    var runnerSecretFile: String = ".worker-secret"

    @Option(name: .long, help: "Number of simulated result views that poll a submission status")
    var statusPollers: Int = 0

    @Option(name: .long, help: "Seconds between the polls of one result view")
    var statusPollInterval: Double = 2

    @Option(name: .long, help: "Submission ID the result views poll")
    var submissionID: String?

    @Option(name: .long, help: "Cookie header of a signed-in session that can read the submission")
    var sessionCookie: String?

    func validate() throws {
        guard duration > 0 else { throw ValidationError("--duration must be more than 0.") }
        guard runners >= 0, statusPollers >= 0 else {
            throw ValidationError("--runners and --status-pollers must be 0 or more.")
        }
        guard runners + statusPollers > 0 else {
            throw ValidationError("Set --runners or --status-pollers to more than 0.")
        }
        guard runnerPollInterval > 0, statusPollInterval > 0 else {
            throw ValidationError("The poll intervals must be more than 0.")
        }
        if statusPollers > 0, submissionID == nil || sessionCookie == nil {
            throw ValidationError("--status-pollers needs --submission-id and --session-cookie.")
        }
    }

    func run() async throws {
        let target = try LoadTarget(baseURL: baseURL, allowRemote: allowRemote)
        let secret = runners > 0 ? try readRunnerSecret() : ""
        let recorder = LatencyRecorder()
        let loadRun = LoadRun(
            deadline: ContinuousClock.now + .seconds(duration),
            client: HTTPClient.shared,
            recorder: recorder
        )

        print("Loading \(target.baseURL.absoluteString) for \(duration) s:")
        print("  \(runners) runner slots, one poll each \(runnerPollInterval) s")
        print("  \(statusPollers) result views, one poll each \(statusPollInterval) s")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<runners {
                let workerID = "loadtest-runner-\(index)"
                group.addTask {
                    await loadRun.drive(
                        .runnerPoll,
                        interval: runnerPollInterval,
                        offsetFraction: Double(index) / Double(runners)
                    ) {
                        try PlannedRequest.runnerPoll(target: target, workerID: workerID, secret: secret)
                    }
                }
            }
            if let submissionID, let sessionCookie {
                for index in 0..<statusPollers {
                    group.addTask {
                        await loadRun.drive(
                            .statusPoll,
                            interval: statusPollInterval,
                            offsetFraction: Double(index) / Double(statusPollers)
                        ) {
                            PlannedRequest.statusPoll(
                                target: target, submissionID: submissionID, sessionCookie: sessionCookie)
                        }
                    }
                }
            }
        }

        for scenario in LoadScenario.allCases {
            let summary = await recorder.summary(for: scenario)
            guard summary.requestCount + summary.transportErrors > 0 else { continue }
            print("")
            print(LoadReport.lines(for: scenario, summary: summary, durationSeconds: duration).joined(separator: "\n"))
        }
    }

    /// Reads the secret from the file the server writes at startup. It is
    /// not the runner's lookup order (`resolveWorkerSharedSecret`): the tool
    /// runs beside a local server, so the server's own file is the source.
    private func readRunnerSecret() throws -> String {
        let contents = (try? String(contentsOfFile: runnerSecretFile, encoding: .utf8)) ?? ""
        let secret = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            throw ValidationError(
                "No runner secret in \(runnerSecretFile). Run the tool in the server directory, or pass --runner-secret-file."
            )
        }
        return secret
    }
}
