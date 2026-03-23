// APIServer/Routes/Web/WebRoutes+Submission.swift
//
// Submission-related handlers and helpers for WebRoutes.
// Extracted from WebRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation

extension WebRoutes {

    // MARK: - GET /testsetups/:id/submit

    @Sendable
    func submitForm(req: Request) async throws -> View {
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.view.render("submit",
            SubmitContext(testSetupID: setupID, currentUser: req.currentUserContext))
    }

    // MARK: - POST /testsetups/:id/submit

    @Sendable
    func createSubmission(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body    = try req.content.decode(SubmitFormBody.self)
        let subsDir = req.application.submissionsDirectory
        let subID   = "sub_\(UUID().uuidString.lowercased().prefix(8))"

        // Detect whether the upload is a zip by checking PK magic bytes.
        let isZip     = body.files.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
        let ext: String = {
            if isZip { return "zip" }
            return inferredRawSubmissionExtension(data: body.files, uploadFilename: body.uploadFilename)
        }()
        let storedExt = isZip ? "zip" : ext
        let filePath  = subsDir + "\(subID).\(storedExt)"
        try body.files.write(to: URL(fileURLWithPath: filePath))
        let fallbackFilename = isZip ? nil : (body.uploadFilename ?? "submission.\(storedExt)")

        // Attempt number is scoped to this student for this test setup.
        let priorCount = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == user.id)
            .filter(\.$kind == APISubmission.Kind.student)
            .count()

        let submission = APISubmission(
            id:            subID,
            testSetupID:   setupID,
            zipPath:       filePath,
            attemptNumber: priorCount + 1,
            filename:      fallbackFilename,
            userID:        user.id,
            kind:          APISubmission.Kind.student
        )
        try await submission.save(on: req.db)
        await ensureLocalRunnerForSubmissionIfNeeded(req: req)

        return req.redirect(to: "/submissions/\(subID)")
    }

    // MARK: - GET /testsetups/:id/history

    @Sendable
    func submissionHistoryPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let _ = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let title = assignment?.title ?? setupID

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()

        let submissionIDs = submissions.compactMap(\.id)
        var preferredResultBySubmissionID: [String: APIResult] = [:]
        if !submissionIDs.isEmpty {
            let results = try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .sort(\.$receivedAt, .descending)
                .all()
            for row in results {
                let key = row.submissionID
                if let existing = preferredResultBySubmissionID[key] {
                    let existingSource = existing.source ?? "worker"
                    let currentSource = row.source ?? "worker"
                    if existingSource == "worker" { continue }
                    if currentSource == "worker" {
                        preferredResultBySubmissionID[key] = row
                    }
                } else {
                    preferredResultBySubmissionID[key] = row
                }
            }
        }

        let rows = submissions.map { submission -> SubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let result = preferredResultBySubmissionID[subID],
               let pct = gradePercentFromCollectionJSON(result.collectionJSON) {
                gradeText = "\(pct)%"
            } else {
                gradeText = "—"
            }
            let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
            let nameExt = (submission.filename ?? "").lowercased()
            let canOpenInNotebook = pathExt == "ipynb" || nameExt.hasSuffix(".ipynb")
            let openInNotebookURL = canOpenInNotebook
                ? "/testsetups/\(setupID)/notebook?submissionID=\(subID)"
                : nil
            return SubmissionHistoryRow(
                submissionID: subID,
                attemptNumber: submission.attemptNumber ?? 1,
                status: submission.status,
                submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
                gradeText: gradeText,
                submissionFilename: submission.filename,
                canOpenInNotebook: canOpenInNotebook,
                openInNotebookURL: openInNotebookURL
            )
        }

        return try await req.view.render("submission-history",
            SubmissionHistoryContext(
                testSetupID: setupID,
                assignmentTitle: title,
                rows: rows,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /submissions/:id

    @Sendable
    func submissionPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)

        guard
            let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Students may only view their own submissions.
        if !user.isInstructor {
            guard submission.userID == user.id else {
                throw Abort(.forbidden)
            }
        }

        // Fetch the assignment for deadline-based tier visibility.
        let submissionAssignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first()
        let allowedTiers = visibleTiers(for: user, assignment: submissionAssignment)

        let isPending         = submission.status == "pending" || submission.status == "assigned"
        let isBrowserComplete = false   // browser submissions now go straight to "complete"
        let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
        let nameExt = (submission.filename ?? "").lowercased()
        let openInNotebookURL: String? = (pathExt == "ipynb" || nameExt.hasSuffix(".ipynb"))
            ? "/testsetups/\(submission.testSetupID)/notebook?submissionID=\(subID)"
            : nil

        var buildFailed     = false
        var compilerOutput: String? = nil
        var outcomes:       [OutcomeRow] = []
        var passCount       = 0
        var totalTests      = 0
        var totalPoints     = 0
        var earnedPoints    = 0
        var executionTimeMs = 0
        var gradePercent    = 0
        var resultSource    = ""   // "browser" | "worker" | ""

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Prefer the worker result (official); fall back to browser result.
        let allResults = try await APIResult.query(on: req.db)
            .filter(\.$submissionID == subID)
            .sort(\.$receivedAt, .descending)
            .all()

        let workerResult  = allResults.first { ($0.source ?? "worker") == "worker" }
        let browserResult = allResults.first { $0.source == "browser" }
        let displayResult = workerResult ?? browserResult

        // Fetch the immediately-prior attempt for per-test delta display.
        let currentAttempt = submission.attemptNumber ?? 1
        var priorOutcomeMap: [String: TestStatus] = [:]
        if currentAttempt > 1, let userID = submission.userID {
            if let priorSub = try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID == submission.testSetupID)
                .filter(\.$userID == userID)
                .filter(\.$attemptNumber == currentAttempt - 1)
                .first(),
               let priorSubID = priorSub.id
            {
                let priorResults = try await APIResult.query(on: req.db)
                    .filter(\.$submissionID == priorSubID)
                    .sort(\.$receivedAt, .descending)
                    .all()
                let priorResult = priorResults.first { ($0.source ?? "worker") == "worker" } ?? priorResults.first
                if let priorResult,
                   let data = priorResult.collectionJSON.data(using: .utf8),
                   let priorCollection = try? decoder.decode(TestOutcomeCollection.self, from: data)
                {
                    for o in priorCollection.outcomes {
                        priorOutcomeMap[o.testName] = o.status
                    }
                }
            }
        }

        // Build a stem→displayName map from the current manifest so the page
        // shows friendly names for both new submissions (where the runner already
        // embedded the name) and old ones (where testName is still the filename stem).
        var displayNameMap: [String: String] = [:]
        if let setup = try? await APITestSetup.find(submission.testSetupID, on: req.db),
           let manifestData = setup.manifest.data(using: .utf8),
           let props = try? JSONDecoder().decode(TestProperties.self, from: manifestData) {
            for entry in props.testSuites {
                guard let displayName = entry.name,
                      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let stem = (entry.script as NSString).deletingPathExtension
                displayNameMap[stem.isEmpty ? entry.script : stem] = displayName
            }
        }

        // Summaries for hidden tiers (students only; instructors see everything directly).
        var releaseSummary: TierSummary? = nil
        var secretSummary:  TierSummary? = nil

        if let result = displayResult {
            resultSource = result.source ?? "worker"
            if let data       = result.collectionJSON.data(using: .utf8),
               let collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
            {
                // Compute per-tier summaries from the full (unfiltered) collection.
                if !user.isInstructor {
                    let releaseOutcomes = collection.outcomes.filter { $0.tier == .release }
                    let secretOutcomes  = collection.outcomes.filter { $0.tier == .secret }
                    let releaseVisible  = allowedTiers.contains("release")
                    if !releaseVisible, !releaseOutcomes.isEmpty {
                        releaseSummary = TierSummary(outcomes: releaseOutcomes, isRelease: true)
                    }
                    if !secretOutcomes.isEmpty {
                        secretSummary = TierSummary(outcomes: secretOutcomes, isRelease: false)
                    }
                }

                let visible     = collection.filtering(tiers: allowedTiers)
                buildFailed     = collection.buildStatus == .failed
                compilerOutput  = collection.compilerOutput
                passCount       = visible.passCount
                totalTests      = visible.totalTests
                executionTimeMs = collection.executionTimeMs
                totalPoints  = visible.totalPoints
                earnedPoints = visible.earnedPoints
                gradePercent = totalPoints > 0
                    ? Int((Double(earnedPoints) / Double(totalPoints) * 100).rounded())
                    : 0
                let weighted = totalPoints != visible.totalTests
                outcomes = visible.outcomes.map { o in
                    let skip = parseSkip(shortResult: o.shortResult)
                    let longOutput: String? = {
                        guard o.status != .pass else { return nil }
                        let s = (o.longResult ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        return s.isEmpty ? nil : s
                    }()
                    let (markLabel, markClass): (String, String) = {
                        if skip.isSkipped { return ("—", "skipped") }
                        switch o.status {
                        case .pass:    return ("Pass",    "pass")
                        case .fail:    return ("Fail",    "fail")
                        case .error:   return ("Error",   "error")
                        case .timeout: return ("Timeout", "timeout")
                        }
                    }()
                    let (deltaImproved, deltaRegressed): (Bool, Bool) = {
                        guard let prior = priorOutcomeMap[o.testName] else { return (false, false) }
                        let wasPass = (prior == .pass)
                        let isPass  = (o.status == .pass)
                        return (!wasPass && isPass, wasPass && !isPass)
                    }()
                    let pointsLabel: String? = weighted && o.points > 1 ? "\(o.points) pts" : nil
                    return OutcomeRow(
                        testName:       displayNameMap[o.testName] ?? o.testName,
                        tier:           o.tier.rawValue,
                        status:         o.status.rawValue,
                        shortResult:    o.shortResult,
                        longResult:     longOutput,
                        markLabel:      markLabel,
                        markClass:      markClass,
                        isSkipped:      skip.isSkipped,
                        blockerName:    skip.blockerName,
                        deltaImproved:  deltaImproved,
                        deltaRegressed: deltaRegressed,
                        pointsLabel:    pointsLabel
                    )
                }
            }
        }

        let hasDelta = !priorOutcomeMap.isEmpty
        let deltaHeaderText: String? = {
            guard hasDelta else { return nil }
            let improved  = outcomes.filter { $0.deltaImproved  }.count
            let regressed = outcomes.filter { $0.deltaRegressed }.count
            var parts: [String] = []
            if improved  > 0 { parts.append("↑ fixed \(improved) test\(improved  == 1 ? "" : "s")") }
            if regressed > 0 { parts.append("↓ broke \(regressed) test\(regressed == 1 ? "" : "s")") }
            if parts.isEmpty { return "No change since attempt \(currentAttempt - 1)" }
            return parts.joined(separator: " · ") + " since attempt \(currentAttempt - 1)"
        }()

        let ctx = SubmissionContext(
            submissionID:      subID,
            testSetupID:       submission.testSetupID,
            status:            submission.status,
            attemptNumber:     submission.attemptNumber ?? 1,
            submissionFilename: submission.filename,
            openInNotebookURL: openInNotebookURL,
            isPending:         isPending,
            isBrowserComplete: isBrowserComplete,
            resultSource:      resultSource,
            buildFailed:       buildFailed,
            compilerOutput:    compilerOutput,
            outcomes:          outcomes,
            passCount:         passCount,
            totalTests:        totalTests,
            gradePercent:      gradePercent,
            executionTimeMs:   executionTimeMs,
            isWeighted:        totalPoints != totalTests,
            totalPoints:       totalPoints,
            earnedPoints:      earnedPoints,
            hasDelta:          hasDelta,
            deltaHeaderText:   deltaHeaderText,
            releaseSummary:    releaseSummary,
            secretSummary:     secretSummary,
            currentUser:       req.currentUserContext
        )
        return try await req.view.render("submission", ctx)
    }
}

// MARK: - Submission helpers

struct SubmitFormBody: Content {
    var files: Data
    /// Original filename from the browser's multipart upload (nil for older clients).
    var uploadFilename: String?
}

/// Detects the dependency-skip message format and extracts the blocking test name.
/// Matches: `Skipped: prerequisite 'test_build.py' did not pass`
func parseSkip(shortResult: String) -> (isSkipped: Bool, blockerName: String?) {
    let prefix = "Skipped: prerequisite '"
    let suffix = "' did not pass"
    guard shortResult.hasPrefix(prefix), shortResult.hasSuffix(suffix) else { return (false, nil) }
    let start = shortResult.index(shortResult.startIndex, offsetBy: prefix.count)
    let end   = shortResult.index(shortResult.endIndex,   offsetBy: -suffix.count)
    guard start <= end else { return (false, nil) }
    let raw = String(shortResult[start..<end])
    // Strip file extension so "test_build.py" becomes "test_build"
    let name: String
    if let dot = raw.lastIndex(of: ".") {
        name = String(raw[..<dot])
    } else {
        name = raw
    }
    return (true, name.isEmpty ? nil : name)
}

func stderrScriptOutput(from raw: String?, status: TestStatus) -> String? {
    guard status != .pass else { return nil }
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let stderr = extractLabeledOutputSection("stderr", in: trimmed) {
        return stderr
    }
    if extractLabeledOutputSection("stdout", in: trimmed) != nil {
        return nil
    }
    return trimmed
}

func extractLabeledOutputSection(_ label: String, in text: String) -> String? {
    let marker = "\(label):\n"
    guard let start = text.range(of: marker) else { return nil }
    let body = text[start.upperBound...]

    if let nextSection = body.range(of: #"\n\n[a-zA-Z_]+:\n"#, options: .regularExpression) {
        let section = String(body[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }
    let section = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
    return section.isEmpty ? nil : section
}

func inferredRawSubmissionExtension(data: Data, uploadFilename: String?) -> String {
    if let uploadFilename {
        let ext = URL(fileURLWithPath: uploadFilename).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty {
            return ext.lowercased()
        }
    }

    // Heuristic: notebook uploads are JSON with "nbformat" key.
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       json["nbformat"] != nil {
        return "ipynb"
    }

    return "txt"
}
