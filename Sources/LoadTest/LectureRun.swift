// LoadTest/LectureRun.swift
//
// One simulated lecture activity, per student, in the four phases that
// docs/load-testing.md ("A lecture activity") lists: join (the notebook page and the kernel boot
// files), work (nothing reaches the server), submit (the browser grader's
// three downloads, the result post, the status poll) and watch (the live
// board's background refresh). Every request is timed and recorded.

import Core
import Foundation
import NIOHTTP1

struct LectureRun: Sendable {
    let exchange: HTTPExchange
    let target: LoadTarget
    let testSetupID: String
    let schedule: LectureSchedule
    let joinMode: JoinMode
    let bootFiles: KernelBootFiles?
    let warmCache: [String: WarmCacheEntry]
    let manifest: TestProperties
    let filesInParallel: Int
    let boardInterval: Double
    let statusInterval: Double
    let recorder: StreamRecorder<LectureStream>
    let start: ContinuousClock.Instant

    private var clock: ContinuousClock { ContinuousClock() }
    private var deadline: ContinuousClock.Instant { start + .milliseconds(Int64(schedule.totalSeconds * 1_000)) }

    private var encodedSetupID: String {
        testSetupID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? testSetupID
    }

    /// One student's whole lecture.
    func student(_ session: StudentSession, index: Int, count: Int) async {
        try? await Task.sleep(until: at(schedule.joinOffset(index: index, count: count)), clock: clock)
        let csrf = await join(session)
        async let watching: Void = watch(session)
        try? await Task.sleep(until: at(schedule.submitOffset(index: index, count: count)), clock: clock)
        await submit(session, csrf: csrf, metric: Double(index))
        await watching
    }

    // MARK: - Join

    /// The page, then the kernel files a few at a time, as a browser
    /// fetches them. Returns the page's CSRF token for the result post.
    private func join(_ session: StudentSession) async -> String? {
        let began = clock.now
        guard
            let page = await timed(
                .page, .GET, "/testsetups/\(encodedSetupID)/notebook", session: session,
                accept: "text/html", keep: 8 << 20)
        else { return nil }
        let csrf = HTMLScrape.csrfToken(in: page.text)
        if joinMode != .page, let bootFiles {
            let paths = bootFiles.paths
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func addNext() {
                    guard next < paths.count else { return }
                    let path = paths[next]
                    next += 1
                    group.addTask { await fetchBootFile(path) }
                }
                for _ in 0..<max(1, filesInParallel) { addNext() }
                for await _ in group { addNext() }
            }
        }
        await recorder.record(.joinSpan, statusCode: 0, durationMs: Self.milliseconds(began.duration(to: clock.now)))
        return csrf
    }

    /// A boot file as the browser asks for it in this join mode. A warm
    /// browser does not ask for an immutable file at all.
    private func fetchBootFile(_ path: String) async {
        var headers: HTTPHeaders = [:]
        if joinMode == .warm, let entry = warmCache[path] {
            if entry.immutable { return }
            if let etag = entry.etag { headers.add(name: "If-None-Match", value: etag) }
            if let modified = entry.lastModified { headers.add(name: "If-Modified-Since", value: modified) }
        }
        _ = await timed(.kernelFile, .GET, path, session: nil, headers: headers, keep: 0)
    }

    // MARK: - Watch

    /// The live board's background refresh until the run ends, with the
    /// ETag the previous answer carried, as `Public/table-poll.js` sends it.
    private func watch(_ session: StudentSession) async {
        var etag: String?
        let period = Duration.milliseconds(Int64(boardInterval * 1_000))
        while clock.now < deadline, !Task.isCancelled {
            let started = clock.now
            var headers: HTTPHeaders = ["X-Background-Refresh": "1"]
            if let etag { headers.add(name: "If-None-Match", value: etag) }
            if let reply = await timed(
                .board, .GET, "/testsetups/\(encodedSetupID)/leaderboard?fragment=body", session: session,
                accept: "text/html", headers: headers, keep: 0),
                let fresh = reply.header("ETag")
            {
                etag = fresh
            }
            try? await Task.sleep(until: min(started + period, deadline), clock: clock)
        }
    }

    // MARK: - Submit

    /// The browser grader's downloads, the result post, then the status
    /// poll until the stored result reads as finished.
    private func submit(_ session: StudentSession, csrf: String?, metric: Double) async {
        let began = clock.now
        let base = "/api/v1/browser-runner/testsetups/\(encodedSetupID)"
        _ = await timed(.setupDownload, .GET, "\(base)/download", session: session, keep: 0)
        _ = await timed(.seedDownload, .GET, "\(base)/seed", session: session, keep: 0)
        _ = await timed(.manifestDownload, .GET, "\(base)/manifest", session: session, keep: 0)

        let collection = SyntheticBrowserResult.collection(
            manifest: manifest, testSetupID: testSetupID, metric: metric)
        guard
            let form = try? SyntheticBrowserResult.multipart(
                collection: collection, notebook: SyntheticBrowserResult.emptyNotebook, testSetupID: testSetupID)
        else { return }
        var headers: HTTPHeaders = ["Content-Type": form.contentType, "Accept": "application/json"]
        if let csrf { headers.add(name: "x-csrf-token", value: csrf) }
        guard
            let posted = await timed(
                .resultPost, .POST, "/api/v1/submissions/browser-result", session: session,
                headers: headers, body: form.body, keep: 1 << 16),
            posted.status == 200,
            let submissionID = Self.submissionID(in: posted.body)
        else { return }

        let encodedID = submissionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? submissionID
        let giveUp = clock.now + .seconds(60)
        while clock.now < giveUp, !Task.isCancelled {
            let polled = clock.now
            guard
                let reply = await timed(
                    .statusPoll, .GET, "/api/v1/submissions/\(encodedID)", session: session,
                    accept: "application/json", keep: 1 << 16),
                reply.status == 200
            else { return }
            if Self.isFinished(statusJSON: reply.body) {
                await recorder.record(
                    .resultVisibleSpan, statusCode: 0, durationMs: Self.milliseconds(began.duration(to: clock.now)))
                return
            }
            try? await Task.sleep(until: polled + .milliseconds(Int64(statusInterval * 1_000)), clock: clock)
        }
    }

    // MARK: - Requests

    /// Sends one request and records it. Nil when no reply came.
    private func timed(
        _ stream: LectureStream,
        _ method: HTTPMethod,
        _ path: String,
        session: StudentSession?,
        accept: String? = nil,
        headers extra: HTTPHeaders = [:],
        body: Data? = nil,
        keep: Int
    ) async -> HTTPReply? {
        var headers = extra
        if let accept { headers.replaceOrAdd(name: "Accept", value: accept) }
        if let session { headers.add(name: "Cookie", value: session.cookieHeader) }
        let started = clock.now
        do {
            let reply = try await exchange.send(
                method, target.url(forPath: path), headers: headers, body: body, keep: keep)
            await recorder.record(
                stream, statusCode: reply.status, durationMs: Self.milliseconds(started.duration(to: clock.now)),
                byteCount: reply.byteCount)
            return reply
        } catch {
            await recorder.recordTransportError(stream)
            return nil
        }
    }

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int64(seconds * 1_000))
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    /// The `submissionID` of a `browser-result` reply.
    static func submissionID(in body: Data) -> String? {
        struct Reply: Decodable { let submissionID: String }
        return try? JSONDecoder().decode(Reply.self, from: body).submissionID
    }

    /// True once a status poll no longer reads as waiting for a runner.
    static func isFinished(statusJSON body: Data) -> Bool {
        struct Reply: Decodable { let status: String }
        guard let status = try? JSONDecoder().decode(Reply.self, from: body).status else { return false }
        return status != "pending" && status != "assigned"
    }
}
