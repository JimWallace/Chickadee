import ArgumentParser
import Core
import Foundation
import NIOHTTP1
import Testing

@testable import chickadee_loadtest

/// The pure parts of `chickadee-loadtest lecture`: what it reads from a
/// page, what it sends, when each student acts, and how the report judges a
/// run. The network run itself is measured against a server, not here.
@Suite struct LectureScenarioTests {
    // MARK: - Options

    @Test func lectureDefaultsAreValid() throws {
        let command = try LectureCommand.parse(["--test-setup-id", "setup_1", "--course-id", "course-1"])
        #expect(command.students == 150)
        #expect(command.joinMode == .cold)
        #expect(command.schedule.totalSeconds == 180)
    }

    @Test func theRootCommandOffersTheLectureSubcommand() throws {
        let parsed = try LoadTestRoot.parseAsRoot([
            "lecture", "--test-setup-id", "setup_1", "--course-id", "course-1", "--students", "3",
        ])
        let lecture = try #require(parsed as? LectureCommand)
        #expect(lecture.students == 3)
    }

    /// The subcommand's own options win: a root option of the same name
    /// once took `--base-url` from the lecture's arguments.
    @Test func theLectureKeepsItsOwnBaseURL() throws {
        let parsed = try LoadTestRoot.parseAsRoot([
            "lecture", "--base-url", "http://localhost:8090", "--test-setup-id", "s", "--course-id", "c",
        ])
        let lecture = try #require(parsed as? LectureCommand)
        #expect(lecture.baseURL == "http://localhost:8090")
    }

    @Test func theHotPathRunIsTheDefault() throws {
        let parsed = try LoadTestRoot.parseAsRoot(["--runners", "4"])
        let hotPaths = try #require(parsed as? LoadTestCommand)
        #expect(hotPaths.runners == 4)
    }

    @Test(arguments: [
        [String](),
        ["--test-setup-id", "setup_1"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--students", "0"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--join", "lukewarm"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--join-window", "90"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--board-interval", "0"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--files-in-parallel", "0"],
        ["--test-setup-id", "setup_1", "--course-id", "c", "--student-password", "short"],
        ["--test-setup-id", "", "--course-id", "c"],
    ])
    func invalidLectureOptionsAreRefused(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try LectureCommand.parse(arguments)
        }
    }

    // MARK: - Reading pages

    @Test func theCSRFTokenComesFromTheMetaTagFirst() {
        let html = #"""
            <html><head><meta charset="utf-8"><meta name="csrf-token" content="salt-abc"></head>
            <body><form><input type="hidden" name="_csrf" value="form-token"></form></body></html>
            """#
        #expect(HTMLScrape.csrfToken(in: html) == "salt-abc")
    }

    @Test func theCSRFTokenFallsBackToTheFormField() {
        let html = #"<form method="post"><input type="hidden" name="_csrf" value="form-token"></form>"#
        #expect(HTMLScrape.csrfToken(in: html) == "form-token")
        #expect(HTMLScrape.csrfToken(in: "<p>no token</p>") == nil)
    }

    @Test func aDataAttributeIsEntityDecoded() throws {
        let html = #"""
            <div id="nb" data-kernel-assets="{&quot;base&quot;:&quot;/jupyterlite/xeus/chickadee-python/&quot;,&quot;bytes&quot;:120,&quot;env&quot;:&quot;chickadee-python&quot;,&quot;files&quot;:[&quot;xpython.wasm&quot;,&quot;/pkgs/numpy.tar.gz&quot;],&quot;version&quot;:&quot;v1&quot;}"></div>
            """#
        let json = try #require(HTMLScrape.dataAttribute("kernel-assets", in: html))
        let files = try #require(KernelBootFiles.decode(json))
        #expect(files.env == "chickadee-python")
        #expect(
            files.paths == [
                "/jupyterlite/xeus/chickadee-python/xpython.wasm",
                "/jupyterlite/xeus/chickadee-python/pkgs/numpy.tar.gz",
            ])
    }

    @Test func anAttributeNameMatchesOnlyAsAWholeName() {
        let tag: Substring = #"meta data-name="other" name="csrf-token""#
        #expect(HTMLScrape.attribute("name", in: tag) == "csrf-token")
        #expect(HTMLScrape.dataAttribute("kernel-assets", in: "<div data-other=\"1\"></div>") == nil)
        #expect(KernelBootFiles.decode("") == nil)
    }

    // MARK: - Browser state

    @Test func theCookieJarFollowsSetCookie() {
        var jar = CookieJar()
        jar.absorb(["Set-Cookie": "vapor-session=abc; Path=/; HttpOnly"])
        jar.absorb(["Set-Cookie": "other=1; Path=/"])
        #expect(jar.header == "other=1; vapor-session=abc")
        jar.absorb(["Set-Cookie": "other=gone; Max-Age=0"])
        #expect(jar.header == "vapor-session=abc")
        #expect(CookieJar(header: "vapor-session=abc") == jar)
        #expect(CookieJar().header == nil)
    }

    @Test func aSessionSurvivesItsSavedLine() throws {
        let session = StudentSession(username: "loadtest-student-4", cookieHeader: "vapor-session=a=b")
        let restored = try #require(StudentSession(line: Substring(session.line)))
        #expect(restored == session)
        #expect(StudentSession(line: "no tab here") == nil)
    }

    @Test func formFieldsAreStrictlyEncoded() {
        let encoded = StudentProvisioning.formEncode([("courseIDs[]", "a b"), ("_csrf", "x+y/z")])
        #expect(encoded == "courseIDs%5B%5D=a%20b&_csrf=x%2By%2Fz")
    }

    @Test func aWarmBrowserSkipsOnlyImmutableFiles() {
        let immutable = WarmCacheEntry(
            cacheControl: "public, max-age=31536000, immutable", etag: nil, lastModified: nil)
        let revalidated = WarmCacheEntry(cacheControl: "no-cache", etag: "\"e1\"", lastModified: nil)
        #expect(immutable.immutable)
        #expect(!revalidated.immutable)
        #expect(!WarmCacheEntry(cacheControl: nil, etag: nil, lastModified: nil).immutable)
    }

    // MARK: - The result post

    @Test func theResultPassesEverySuiteEntryAndDecodesOnTheServer() throws {
        let manifest = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"""
                {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"timeLimitSeconds":10,
                 "testSuites":[{"tier":"public","script":"test_a.py","points":2},
                               {"tier":"secret","script":"test_b.py"}]}
                """#.utf8))
        let collection = SyntheticBrowserResult.collection(manifest: manifest, testSetupID: "setup_1", metric: 7)
        #expect(collection.outcomes.map(\.testName) == ["test_a.py", "test_b.py"])
        #expect(collection.passCount == 2)
        #expect(collection.outcomes.allSatisfy { $0.metric == 7 && $0.status == .pass })

        let form = try SyntheticBrowserResult.multipart(
            collection: collection, notebook: SyntheticBrowserResult.emptyNotebook, testSetupID: "setup_1",
            boundary: "BOUNDARY")
        #expect(form.contentType == "multipart/form-data; boundary=BOUNDARY")
        let text = try #require(String(bytes: form.body, encoding: .utf8))
        #expect(text.contains(#"name="collection""#))
        #expect(text.contains(#"name="notebook"; filename="submission.ipynb""#))
        #expect(text.contains("name=\"testSetupID\"\r\n\r\nsetup_1\r\n"))
        #expect(text.hasSuffix("--BOUNDARY--\r\n"))

        // The collection part is what the server decodes, with ISO 8601 dates.
        let start = try #require(text.range(of: "name=\"collection\"\r\n\r\n"))
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\r\n--BOUNDARY"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: Data(rest[..<end.lowerBound].utf8))
        #expect(decoded.totalTests == 2)
    }

    @Test func theReplyReadersFindTheSubmissionAndItsState() {
        #expect(LectureRun.submissionID(in: Data(#"{"submissionID":"sub_9"}"#.utf8)) == "sub_9")
        #expect(LectureRun.submissionID(in: Data("not json".utf8)) == nil)
        #expect(LectureRun.isFinished(statusJSON: Data(#"{"status":"complete"}"#.utf8)))
        #expect(!LectureRun.isFinished(statusJSON: Data(#"{"status":"pending"}"#.utf8)))
        #expect(!LectureRun.isFinished(statusJSON: Data(#"{"status":"assigned"}"#.utf8)))
        #expect(!LectureRun.isFinished(statusJSON: Data("{}".utf8)))
    }

    // MARK: - Schedule

    @Test func studentsAreSpreadOverTheirWindows() {
        let schedule = LectureSchedule(joinWindow: 30, workSeconds: 60, submitWindow: 60, watchSeconds: 60)
        #expect(schedule.joinOffset(index: 0, count: 150) == 0)
        #expect(schedule.joinOffset(index: 75, count: 150) == 15)
        #expect(schedule.submitOffset(index: 0, count: 150) == 60)
        #expect(schedule.submitOffset(index: 149, count: 150) < 120)
        #expect(schedule.totalSeconds == 180)
    }

    // MARK: - Report

    @Test func theTargetsPassOrFailOnTheMeasuredValues() {
        let fast = LatencySummary(durationsMs: [1_000, 2_000], statusCounts: [:], transportErrors: 0)
        let slow = LatencySummary(durationsMs: [12_000], statusCounts: [:], transportErrors: 0)
        let lines = LectureReport.targetLines(
            joinMode: .warm, join: fast, resultVisible: slow, totals: LectureTotals(serverErrors: 1))
        #expect(lines.contains { $0.hasPrefix("  PASS  Warm join") })
        #expect(lines.contains { $0.hasPrefix("  FAIL  Result visible") })
        #expect(lines.contains { $0.hasPrefix("  FAIL  No server errors: 1 5xx") })

        let cold = LectureReport.targetLines(
            joinMode: .cold, join: slow, resultVisible: fast, totals: LectureTotals())
        #expect(cold.contains { $0.contains("not checked, this run joined cold") })
        #expect(cold.contains { $0.hasPrefix("  PASS  No server errors") })
    }

    @Test func aSpanReportsStudentsNotStatuses() {
        let summary = LatencySummary(durationsMs: [5], statusCounts: [0: 1], transportErrors: 0)
        let span = LectureReport.streamLines(.joinSpan, summary: summary, byteCount: 0, durationSeconds: 10)
        #expect(span.contains("  students:  1"))
        #expect(!span.contains { $0.contains("statuses") })
        #expect(LectureReport.formatBytes(8_700_000_000) == "8.7 GB")
        #expect(LectureReport.formatBytes(512) == "512 bytes")
    }
}
