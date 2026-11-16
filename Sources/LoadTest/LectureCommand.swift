// LoadTest/LectureCommand.swift
//
// `chickadee-loadtest lecture`: simulates one class activity in a lecture
// (work item W1 of the live-lecture plan, pull request #2540). Each simulated student signs in,
// joins the activity's notebook page and boots its kernel, watches the live
// board, and submits a browser-graded result inside the submit window. The
// report gives each stream's latency and checks the plan's targets. See
// docs/load-testing.md, "A lecture activity".

import ArgumentParser
import AsyncHTTPClient
import Core
import Foundation
import NIOHTTP1

struct LectureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lecture",
        abstract: "Simulate one browser-graded class activity in a lecture and check the targets"
    )

    @Option(name: .long, help: "Base URL of the server to load")
    var baseURL: String = "http://localhost:8080"

    @Flag(name: .long, help: "Allow a server that is not on this machine. Never point this at production")
    var allowRemote: Bool = false

    @Option(name: .long, help: "Test setup ID of the activity: a browser-graded, open assignment")
    var testSetupID: String

    @Option(name: .long, help: "ID of the activity's course, which must be open for self-enrolment")
    var courseID: String

    @Option(name: .long, help: "Number of simulated students")
    var students: Int = 150

    @Option(name: .long, help: "Prefix of the simulated students' usernames")
    var studentPrefix: String = "loadtest-student-"

    @Option(name: .long, help: "Password of the simulated students' local accounts, at least 8 characters")
    var studentPassword: String = "loadtest-password"

    @Option(
        name: .long,
        help: "File that keeps the students' sessions between runs. Delete it to sign in again")
    var sessionsFile: String = ".loadtest-lecture-sessions"

    @Option(name: .long, help: "How students join: cold, warm or page (no kernel files)")
    var join: String = JoinMode.cold.rawValue

    @Option(name: .long, help: "Seconds over which the students start to join")
    var joinWindow: Double = 30

    @Option(name: .long, help: "Seconds from the start until the first student submits")
    var workSeconds: Double = 60

    @Option(name: .long, help: "Seconds over which the students submit")
    var submitWindow: Double = 60

    @Option(name: .long, help: "Seconds the board is watched after the last submit")
    var watchSeconds: Double = 60

    @Option(name: .long, help: "Seconds between two board refreshes of one student")
    var boardInterval: Double = 5

    @Option(name: .long, help: "Seconds between two status polls of one student")
    var statusInterval: Double = 2

    @Option(name: .long, help: "Kernel files one student fetches at the same time")
    var filesInParallel: Int = 6

    var joinMode: JoinMode? { JoinMode(rawValue: join) }

    var schedule: LectureSchedule {
        LectureSchedule(
            joinWindow: joinWindow, workSeconds: workSeconds, submitWindow: submitWindow, watchSeconds: watchSeconds)
    }

    func validate() throws {
        guard students > 0 else { throw ValidationError("--students must be more than 0.") }
        guard joinMode != nil else {
            throw ValidationError(
                "--join must be one of: \(JoinMode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard joinWindow >= 0, workSeconds >= 0, submitWindow >= 0, watchSeconds >= 0 else {
            throw ValidationError("The window and phase lengths must be 0 or more.")
        }
        guard joinWindow <= workSeconds else {
            throw ValidationError("--join-window must not be longer than --work-seconds.")
        }
        guard boardInterval > 0, statusInterval > 0 else {
            throw ValidationError("The poll intervals must be more than 0.")
        }
        guard filesInParallel > 0 else { throw ValidationError("--files-in-parallel must be more than 0.") }
        guard studentPassword.count >= 8 else {
            throw ValidationError("--student-password must have at least 8 characters, as the server requires.")
        }
        guard !testSetupID.isEmpty, !courseID.isEmpty else {
            throw ValidationError("--test-setup-id and --course-id must not be empty.")
        }
    }

    func run() async throws {
        let target = try LoadTarget(baseURL: baseURL, allowRemote: allowRemote)
        guard let joinMode else { throw ValidationError("Unknown --join value.") }
        let client = HTTPExchange.makeClient(connectionsPerHost: students * (filesInParallel + 2))
        do {
            try await run(target: target, joinMode: joinMode, exchange: HTTPExchange(client: client))
            try await client.shutdown()
        } catch {
            try? await client.shutdown()
            throw error
        }
    }

    private func run(target: LoadTarget, joinMode: JoinMode, exchange: HTTPExchange) async throws {
        print("Lecture activity \(testSetupID) on \(target.baseURL.absoluteString), \(students) students")
        let sessions = try await provisionSessions(target: target, exchange: exchange)
        let first = sessions[0]

        // Before the clock starts: the page, so the run fetches the boot
        // files the server really lists, and the manifest, for the results.
        let preflight = try await preflight(target: target, exchange: exchange, session: first)
        var warmCache: [String: WarmCacheEntry] = [:]
        if joinMode == .warm, let files = preflight.bootFiles {
            warmCache = try await learnWarmCache(target: target, exchange: exchange, files: files)
        }

        let recorder = StreamRecorder<LectureStream>()
        let lecture = LectureRun(
            exchange: exchange, target: target, testSetupID: testSetupID, schedule: schedule, joinMode: joinMode,
            bootFiles: preflight.bootFiles, warmCache: warmCache, manifest: preflight.manifest,
            filesInParallel: filesInParallel, boardInterval: boardInterval, statusInterval: statusInterval,
            recorder: recorder, start: ContinuousClock.now)

        print(
            "Running for \(LoadReport.format(schedule.totalSeconds)) s: join over \(LoadReport.format(joinWindow)) s "
                + "(\(joinMode.rawValue)), submit from \(LoadReport.format(workSeconds)) s over "
                + "\(LoadReport.format(submitWindow)) s, then watch for \(LoadReport.format(watchSeconds)) s")
        await withTaskGroup(of: Void.self) { group in
            for (index, session) in sessions.enumerated() {
                group.addTask { await lecture.student(session, index: index, count: sessions.count) }
            }
        }
        await printReport(recorder: recorder, joinMode: joinMode)
    }

    // MARK: - Before the run

    private struct Preflight {
        let bootFiles: KernelBootFiles?
        let manifest: TestProperties
    }

    private func preflight(
        target: LoadTarget, exchange: HTTPExchange, session: StudentSession
    ) async throws
        -> Preflight
    {
        let encodedID = testSetupID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? testSetupID
        let headers: HTTPHeaders = ["Cookie": session.cookieHeader, "Accept": "text/html"]
        let page = try await exchange.send(
            .GET, target.url(forPath: "/testsetups/\(encodedID)/notebook"), headers: headers, keep: 8 << 20)
        guard page.status == 200 else {
            throw ValidationError(
                "The notebook page answered \(page.status) for \(session.username). Is the assignment open, "
                    + "and is it in the course \(courseID)?")
        }
        let bootFiles = HTMLScrape.dataAttribute("kernel-assets", in: page.text).flatMap(KernelBootFiles.decode)
        if let bootFiles {
            print(
                "Kernel \(bootFiles.env): \(bootFiles.files.count) boot files, "
                    + "\(LectureReport.formatBytes(bootFiles.bytes)) on disk")
        } else {
            print("The page lists no kernel boot files, so the join is the page only.")
        }

        let manifestReply = try await exchange.send(
            .GET, target.url(forPath: "/api/v1/browser-runner/testsetups/\(encodedID)/manifest"),
            headers: ["Cookie": session.cookieHeader], keep: 4 << 20)
        guard manifestReply.status == 200,
            let manifest = try? JSONDecoder().decode(TestProperties.self, from: manifestReply.body)
        else {
            throw ValidationError("Could not read the manifest (HTTP \(manifestReply.status)).")
        }
        guard manifest.effectiveGradingMode == .browser else {
            throw ValidationError("The assignment is not graded in the browser, so the server refuses its results.")
        }
        return Preflight(bootFiles: bootFiles, manifest: manifest)
    }

    /// One fetch of each boot file, to learn how a warm browser would ask.
    private func learnWarmCache(
        target: LoadTarget, exchange: HTTPExchange, files: KernelBootFiles
    ) async throws
        -> [String: WarmCacheEntry]
    {
        var cache: [String: WarmCacheEntry] = [:]
        for path in files.paths {
            let reply = try await exchange.send(.GET, target.url(forPath: path), keep: 0)
            cache[path] = WarmCacheEntry(
                cacheControl: reply.header("Cache-Control"), etag: reply.header("ETag"),
                lastModified: reply.header("Last-Modified"))
        }
        let immutable = cache.values.count(where: \.immutable)
        print("Warm join: \(immutable) of \(cache.count) boot files are immutable and are not asked for")
        return cache
    }

    // MARK: - Sessions

    private func provisionSessions(target: LoadTarget, exchange: HTTPExchange) async throws -> [StudentSession] {
        let saved = loadSavedSessions()
        if saved.count >= students {
            print("Using \(students) saved sessions from \(sessionsFile)")
            return Array(saved.prefix(students))
        }
        print("Signing in \(students) students (\(studentPrefix)0 to \(studentPrefix)\(students - 1))")
        let provisioning = StudentProvisioning(
            exchange: exchange, target: target, courseID: courseID, password: studentPassword)
        var sessions: [StudentSession] = []
        // A few at a time: this is set-up, not load.
        let batch = 8
        for start in stride(from: 0, to: students, by: batch) {
            let names = (start..<min(start + batch, students)).map { "\(studentPrefix)\($0)" }
            let made = try await withThrowingTaskGroup(of: (Int, StudentSession).self) { group in
                for (offset, name) in names.enumerated() {
                    group.addTask { (offset, try await provisioning.session(for: name)) }
                }
                var found: [(Int, StudentSession)] = []
                for try await item in group { found.append(item) }
                return found.sorted { $0.0 < $1.0 }.map(\.1)
            }
            sessions.append(contentsOf: made)
        }
        saveSessions(sessions)
        return sessions
    }

    private func loadSavedSessions() -> [StudentSession] {
        guard let text = try? String(contentsOfFile: sessionsFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap(StudentSession.init(line:))
            .filter { $0.username.hasPrefix(studentPrefix) }
    }

    private func saveSessions(_ sessions: [StudentSession]) {
        let text = sessions.map(\.line).joined(separator: "\n") + "\n"
        do {
            try text.write(toFile: sessionsFile, atomically: true, encoding: .utf8)
        } catch {
            print("Could not save the sessions to \(sessionsFile): \(error)")
        }
    }

    // MARK: - Report

    private func printReport(recorder: StreamRecorder<LectureStream>, joinMode: JoinMode) async {
        var totals = LectureTotals()
        for stream in LectureStream.allCases {
            let summary = await recorder.summary(for: stream)
            guard summary.requestCount + summary.transportErrors > 0 else { continue }
            let bytes = await recorder.byteCount(for: stream)
            print("")
            print(
                LectureReport.streamLines(
                    stream, summary: summary, byteCount: bytes, durationSeconds: schedule.totalSeconds
                ).joined(separator: "\n"))
            guard !stream.isSpan else { continue }
            totals.serverErrors += summary.statusCounts.filter { $0.key >= 500 }.values.reduce(0, +)
            totals.transportErrors += summary.transportErrors
            if stream != .kernelFile {
                totals.signInRedirects += summary.statusCounts.filter { (300..<400).contains($0.key) && $0.key != 304 }
                    .values.reduce(
                        0, +)
            }
        }
        print("")
        print(
            LectureReport.targetLines(
                joinMode: joinMode,
                join: await recorder.summary(for: .joinSpan),
                resultVisible: await recorder.summary(for: .resultVisibleSpan),
                totals: totals
            ).joined(separator: "\n"))
    }
}
