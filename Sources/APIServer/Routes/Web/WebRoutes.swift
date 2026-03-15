// APIServer/Routes/Web/WebRoutes.swift
//
// Browser-facing routes for the Chickadee web UI.
// All routes in this collection require authentication (enforced by RoleMiddleware
// in routes.swift). Instructor-only routes (testsetups/new) are in a separate
// group in routes.swift.
//
//   GET  /                          → index.leaf      (assignments)
//   GET  /testsetups/new            → setup-new.leaf  (instructor upload form)
//   POST /testsetups/new            → save test setup, redirect to /
//   GET  /testsetups/:id/submit     → submit.leaf     (student submission form)
//   POST /testsetups/:id/submit     → save submission, redirect to /submissions/:id
//   GET  /testsetups/:id/notebook   → notebook.leaf   (JupyterLite in-browser editor)
//   GET  /submissions/:id           → submission.leaf (live results)

import Vapor
import Fluent
import Leaf
import Core
import Foundation
import Crypto

struct WebRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(use: index)
        routes.get("testsetups", "new", use: newSetupForm)
        routes.post("testsetups", "new", use: createSetup)
        routes.get("testsetups", ":testSetupID", "submit", use: submitForm)
        routes.post("testsetups", ":testSetupID", "submit", use: createSubmission)
        routes.get("testsetups", ":testSetupID", "history", use: submissionHistoryPage)
        routes.get("testsetups", ":testSetupID", "notebook", use: notebookPage)
        routes.get("testsetups", ":testSetupID", "notebook", "source", use: notebookSource)
        routes.get("submissions", ":submissionID", use: submissionPage)
    }

    // MARK: - GET /

    @Sendable
    func index(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        // Resolve active course and build course-aware user context for tabs.
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user,
            activeCourse: courseState.active,
            enrolledCourses: courseState.all
        )

        // If active (non-archived) courses exist but user has no active enrollment → redirect to /enroll.
        if courseState.active == nil {
            let activeCourseCount = try await APICourse.query(on: req.db)
                .filter(\.$isArchived == false)
                .count()
            if activeCourseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        let decoder = JSONDecoder()
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

        // Load assignments, filtering by active course when one is resolved.
        let allAssignments: [APIAssignment]
        if let activeCourseUUID = courseState.activeCourseUUID {
            allAssignments = try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .all()
        } else {
            allAssignments = try await APIAssignment.query(on: req.db).all()
        }
        let openAssignments = allAssignments.filter(\.isOpen)
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let setups: [APITestSetup]
        if user.isInstructor {
            // Instructors and admins see test setups for the active course.
            if let activeCourseUUID = courseState.activeCourseUUID {
                setups = try await APITestSetup.query(on: req.db)
                    .filter(\.$courseID == activeCourseUUID)
                    .sort(\.$createdAt, .descending)
                    .all()
            } else {
                setups = try await APITestSetup.query(on: req.db)
                    .sort(\.$createdAt, .descending)
                    .all()
            }
        } else {
            // Students see only test setups that have an open published assignment.
            let publishedIDs = Set(openAssignments.map(\.testSetupID))
            guard !publishedIDs.isEmpty else {
                return try await req.view.render("index",
                    IndexContext(sections: [], ungroupedSetups: [], hasSections: false, hasUngrouped: false, currentUser: userContext)).encodeResponse(for: req)
            }
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ publishedIDs)
                .sort(\.$createdAt, .descending)
                .all()
        }

        var latestSubmissionBySetupID: [String: LatestSubmissionItem] = [:]
        var submissionCountBySetupID: [String: Int] = [:]
        var bestGradePercentBySetupID: [String: Int] = [:]
        if let userID = user.id {
            let setupIDs = setups.compactMap(\.id)
            if !setupIDs.isEmpty {
                let submissions = try await APISubmission.query(on: req.db)
                    .filter(\.$userID == userID)
                    .filter(\.$testSetupID ~~ setupIDs)
                    .filter(\.$kind == APISubmission.Kind.student)
                    .sort(\.$submittedAt, .descending)
                    .all()

                var grouped: [String: [APISubmission]] = [:]
                for submission in submissions {
                    grouped[submission.testSetupID, default: []].append(submission)
                }

                for (setupID, items) in grouped {
                    submissionCountBySetupID[setupID] = items.count
                    if let latest = items.first {
                        let when = latest.submittedAt.map { fmt.string(from: $0) } ?? "—"
                        latestSubmissionBySetupID[setupID] = LatestSubmissionItem(
                            submissionID: latest.id ?? "",
                            submittedAtText: when
                        )
                    }
                }

                let submissionIDs = submissions.compactMap(\.id)
                if !submissionIDs.isEmpty {
                    let resultRows = try await APIResult.query(on: req.db)
                        .filter(\.$submissionID ~~ submissionIDs)
                        .sort(\.$receivedAt, .descending)
                        .all()

                    // Keep one preferred result per submission:
                    // worker result first; browser result only if no worker exists.
                    var preferredResultBySubmissionID: [String: APIResult] = [:]
                    for row in resultRows {
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

                    for submission in submissions {
                        guard let subID = submission.id,
                              let result = preferredResultBySubmissionID[subID],
                              let gradePercent = gradePercentFromCollectionJSON(result.collectionJSON) else {
                            continue
                        }
                        let setupID = submission.testSetupID
                        let existing = bestGradePercentBySetupID[setupID] ?? 0
                        if gradePercent > existing {
                            bestGradePercentBySetupID[setupID] = gradePercent
                        }
                    }
                }
            }
        }

        let sortedSetups = setups.sorted { lhs, rhs in
            let lhsID = lhs.id ?? ""
            let rhsID = rhs.id ?? ""
            let lhsOrder = assignmentBySetup[lhsID]?.sortOrder
            let rhsOrder = assignmentBySetup[rhsID]?.sortOrder

            switch (lhsOrder, rhsOrder) {
            case let (l?, r?) where l != r:
                return l < r
            default:
                let lhsCreated = lhs.createdAt ?? .distantPast
                let rhsCreated = rhs.createdAt ?? .distantPast
                if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
                return lhsID < rhsID
            }
        }

        let rows = sortedSetups.map { setup -> TestSetupRow in
            let setupID    = setup.id ?? ""
            let data       = Data(setup.manifest.utf8)
            let props      = try? decoder.decode(TestProperties.self, from: data)
            let assignment = assignmentBySetup[setupID]
            let latestSubmission = latestSubmissionBySetupID[setupID]
            let submissionCount = submissionCountBySetupID[setupID] ?? 0
            let status: String
            if let assignment {
                status = assignment.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }
            return TestSetupRow(
                id:         setupID,
                title:      assignment?.title,
                suiteCount: props?.testSuites.count ?? 0,
                createdAt:  setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                dueAt:      assignment?.dueAt.map { fmt.string(from: $0) },
                status:     status,
                isOpen:     assignment?.isOpen ?? false,
                submissionCount: submissionCount,
                hasLatestSubmission: latestSubmission != nil,
                latestSubmissionID: latestSubmission?.submissionID ?? "",
                latestSubmittedAtText: latestSubmission?.submittedAtText ?? "—",
                additionalSubmissionCount: max(submissionCount - 1, 0),
                bestGradeText: bestGradePercentBySetupID[setupID].map { "\($0)%" }
            )
        }

        // Fetch sections for the active course to enable grouped display.
        let allSections: [APICourseSection]
        if let activeCourseUUID = courseState.activeCourseUUID {
            allSections = try await APICourseSection.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$sortOrder, .ascending)
                .all()
        } else {
            allSections = []
        }

        // Build lookup: testSetupID → section UUID
        let sectionBySetupID: [String: UUID] = Dictionary(
            allAssignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.testSetupID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Group rows by section; rows without a matching section → ungrouped.
        var rowsBySectionID: [UUID: [TestSetupRow]] = [:]
        var ungroupedSetups: [TestSetupRow] = []
        for row in rows {
            if let sID = sectionBySetupID[row.id] {
                rowsBySectionID[sID, default: []].append(row)
            } else {
                ungroupedSetups.append(row)
            }
        }

        // Build per-section contexts, skipping sections with no visible items.
        let sectionContexts: [IndexSectionContext] = allSections.compactMap { section in
            guard let sID = section.id else { return nil }
            let sectionRows = rowsBySectionID[sID] ?? []
            guard !sectionRows.isEmpty else { return nil }
            return IndexSectionContext(sectionID: sID.uuidString, name: section.name, setups: sectionRows)
        }

        return try await req.view.render("index",
            IndexContext(
                sections: sectionContexts,
                ungroupedSetups: ungroupedSetups,
                hasSections: !allSections.isEmpty,
                hasUngrouped: !ungroupedSetups.isEmpty,
                currentUser: userContext
            )).encodeResponse(for: req)
    }

    // MARK: - GET /testsetups/new

    @Sendable
    func newSetupForm(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }
        return try await req.view.render("setup-new",
            BaseContext(currentUser: req.currentUserContext))
    }

    // MARK: - POST /testsetups/new

    @Sendable
    func createSetup(req: Request) async throws -> Response {
        let setupUser = try req.auth.require(APIUser.self)
        guard setupUser.isInstructor else { throw Abort(.forbidden) }
        let upload = try req.content.decode(TestSetupUpload.self)

        let manifestData = Data(upload.manifest.utf8)
        let decoder      = JSONDecoder()
        let manifest: TestProperties
        do {
            manifest = try decoder.decode(TestProperties.self, from: manifestData)
        } catch {
            throw Abort(.badRequest, reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw Abort(.badRequest, reason: "Unsupported schemaVersion; expected 1")
        }

        let setupsDir = req.application.testSetupsDirectory
        let setupID   = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath   = setupsDir + "\(setupID).zip"
        try upload.files.write(to: URL(fileURLWithPath: zipPath))

        let encoder = JSONEncoder()
        let stored  = String(data: try encoder.encode(manifest), encoding: .utf8) ?? upload.manifest

        // Associate the setup with the instructor's active course.
        let courseState = try await req.resolveActiveCourse(for: setupUser)
        guard let courseID = courseState.activeCourseUUID else {
            throw Abort(.badRequest, reason: "No active course selected. Please select a course before uploading a test setup.")
        }
        let setup = APITestSetup(id: setupID, manifest: stored, zipPath: zipPath,
                                  courseID: courseID)
        try await setup.save(on: req.db)

        return req.redirect(to: "/")
    }

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

    // MARK: - GET /testsetups/:id/notebook

    @Sendable
    func notebookPage(req: Request) async throws -> View {
        struct NotebookQuery: Content {
            var title: String?
            var submissionID: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let query = try? req.query.decode(NotebookQuery.self)
        let queryTitle = (query?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let dbTitle = (assignment?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentTitle = {
            if !queryTitle.isEmpty { return queryTitle }
            if !dbTitle.isEmpty { return dbTitle }
            return "Assignment"
        }()
        let requestedSubmissionID = (query?.submissionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedSubmissionID.isEmpty {
            let notebookData = try await notebookDataForHistorySelection(
                req: req,
                submissionID: requestedSubmissionID,
                setupID: setupID,
                userID: userID
            )
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup,
                overwriteWith: notebookData
            )
        } else {
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setupID,
                userID: userID,
                fallbackSetup: setup
            )
        }
        let jupyterLiteNotebookPath = userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
        let encodedPath = jupyterLiteNotebookPath.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)
            ?? jupyterLiteNotebookPath
        let userSlug = userID.uuidString.lowercased()
        let workspaceID = "\(setupID)-\(userSlug)-student"
        let editorURL = "/jupyterlite/notebooks/index.html?workspace=\(workspaceID)&reset=&path=\(encodedPath)"

        // Decode gradingMode from the manifest so the template can load
        // browser-runner.js for browser-graded assignments.
        let manifestGradingMode: String = {
            let data = Data(setup.manifest.utf8)
            guard let manifest = try? JSONDecoder().decode(TestProperties.self, from: data) else {
                return GradingMode.browser.rawValue
            }
            return manifest.gradingMode.rawValue
        }()

        return try await req.view.render("notebook",
            NotebookContext(
                testSetupID: setupID,
                assignmentTitle: assignmentTitle,
                notebookURL: "/testsetups/\(setupID)/notebook/source",
                jupyterLiteEditorURL: editorURL,
                gradingMode: manifestGradingMode,
                currentUser: req.currentUserContext
            ))
    }

    // MARK: - GET /testsetups/:id/notebook/source

    @Sendable
    func notebookSource(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.unauthorized) }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let payload = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setupID,
            userID: userID,
            fallbackSetup: setup
        )

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(data: payload))
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

        if let result = displayResult {
            resultSource = result.source ?? "worker"
            if let data       = result.collectionJSON.data(using: .utf8),
               let collection = try? decoder.decode(TestOutcomeCollection.self, from: data)
            {
                let visible     = collection.filtering(tiers: allowedTiers)
                buildFailed     = collection.buildStatus == .failed
                compilerOutput  = collection.compilerOutput
                passCount       = visible.passCount
                totalTests      = visible.totalTests
                executionTimeMs = collection.executionTimeMs
                gradePercent    = visible.totalTests > 0
                    ? Int((Double(visible.passCount) / Double(visible.totalTests) * 100).rounded())
                    : 0
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
                    return OutcomeRow(
                        testName:       o.testName,
                        tier:           o.tier.rawValue,
                        status:         o.status.rawValue,
                        shortResult:    o.shortResult,
                        longResult:     longOutput,
                        markLabel:      markLabel,
                        markClass:      markClass,
                        isSkipped:      skip.isSkipped,
                        blockerName:    skip.blockerName,
                        deltaImproved:  deltaImproved,
                        deltaRegressed: deltaRegressed
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
            hasDelta:          hasDelta,
            deltaHeaderText:   deltaHeaderText,
            currentUser:       req.currentUserContext
        )
        return try await req.view.render("submission", ctx)
    }
}

// MARK: - Context types

private struct BaseContext: Encodable {
    let currentUser: CurrentUserContext?
}

private struct TestSetupRow: Encodable {
    let id: String
    let title: String?      // from APIAssignment; nil when instructor sees unpublished setups
    let suiteCount: Int
    let createdAt: String
    let dueAt: String?      // formatted due date, nil if no assignment or no due date
    let status: String      // "unpublished" | "open" | "closed"
    let isOpen: Bool
    let submissionCount: Int
    let hasLatestSubmission: Bool
    let latestSubmissionID: String
    let latestSubmittedAtText: String
    let additionalSubmissionCount: Int
    let bestGradeText: String?
}

private struct LatestSubmissionItem: Encodable {
    let submissionID: String
    let submittedAtText: String
}

private struct IndexSectionContext: Encodable {
    let sectionID: String
    let name: String
    let setups: [TestSetupRow]
}

private struct IndexContext: Encodable {
    let sections: [IndexSectionContext]     // named sections with their visible items
    let ungroupedSetups: [TestSetupRow]     // items not assigned to any section
    let hasSections: Bool                   // true if the course has any defined sections
    let hasUngrouped: Bool                  // true if there are items not in any section
    let currentUser: CurrentUserContext?
}

private struct SubmitContext: Encodable {
    let testSetupID: String
    let currentUser: CurrentUserContext?
}

private struct NotebookContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let notebookURL: String
    let jupyterLiteEditorURL: String
    let gradingMode: String          // "browser" | "worker"
    let currentUser: CurrentUserContext?
}

private struct SubmissionHistoryContext: Encodable {
    let testSetupID: String
    let assignmentTitle: String
    let rows: [SubmissionHistoryRow]
    let currentUser: CurrentUserContext?
}

private struct SubmissionHistoryRow: Encodable {
    let submissionID: String
    let attemptNumber: Int
    let status: String
    let submittedAt: String
    let gradeText: String
    let canOpenInNotebook: Bool
    let openInNotebookURL: String?
}

private struct OutcomeRow: Encodable {
    let testName: String
    let tier: String
    let status: String           // pass | fail | error | timeout
    let shortResult: String
    let longResult: String?      // full output shown in <details>; nil for passing tests
    let markLabel: String        // Pass | Fail | Error | Timeout | —
    let markClass: String        // pass | fail | error | timeout | skipped
    let isSkipped: Bool          // shortResult matches the dependency-skip pattern
    let blockerName: String?     // extracted prerequisite name ("test_build"), no extension
    let deltaImproved: Bool      // was non-pass last attempt, is pass now
    let deltaRegressed: Bool     // was pass last attempt, is non-pass now
}

private struct SubmissionContext: Encodable {
    let submissionID: String
    let testSetupID: String
    let status: String
    let attemptNumber: Int
    let openInNotebookURL: String?
    let isPending: Bool
    /// True when the browser run is done but the worker hasn't reported yet.
    let isBrowserComplete: Bool
    /// "browser" or "worker" — which result is currently displayed.
    let resultSource: String
    let buildFailed: Bool
    let compilerOutput: String?
    let outcomes: [OutcomeRow]
    let passCount: Int
    let totalTests: Int
    let gradePercent: Int
    let executionTimeMs: Int
    /// True when a prior attempt exists and delta data is populated.
    let hasDelta: Bool
    /// E.g. "↑ fixed 2 tests · ↓ broke 1 test since attempt 3"; nil on first attempt.
    let deltaHeaderText: String?
    let currentUser: CurrentUserContext?
}

private func userNotebookWorkingCopyRelativePath(setupID: String, userID: UUID) -> String {
    "users/\(userID.uuidString.lowercased())/\(setupID)/assignment.ipynb"
}

private func userNotebookWorkingCopyAbsolutePath(req: Request, setupID: String, userID: UUID) -> String {
    req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID)
}

private func ensureUserNotebookWorkingCopy(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup,
    overwriteWith: Data? = nil
) async throws -> Data {
    let fileManager = FileManager.default
    let workingCopyPath = userNotebookWorkingCopyAbsolutePath(req: req, setupID: setupID, userID: userID)
    let workingCopyDir = (workingCopyPath as NSString).deletingLastPathComponent

    if let overwriteWith {
        try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
        try overwriteWith.write(to: URL(fileURLWithPath: workingCopyPath))
        removeLegacyUserNotebookCopies(req: req, userID: userID)
        return overwriteWith
    }

    if let existingData = try? Data(contentsOf: URL(fileURLWithPath: workingCopyPath)),
       !existingData.isEmpty,
       (try? JSONSerialization.jsonObject(with: existingData)) != nil {
        removeLegacyUserNotebookCopies(req: req, userID: userID)
        return existingData
    }

    let seedData = try await latestNotebookSubmissionData(
        req: req,
        setupID: setupID,
        userID: userID,
        fallbackSetup: fallbackSetup
    ).data

    try fileManager.createDirectory(atPath: workingCopyDir, withIntermediateDirectories: true)
    try seedData.write(to: URL(fileURLWithPath: workingCopyPath))

    removeLegacyUserNotebookCopies(req: req, userID: userID)
    return seedData
}

private func notebookDataForHistorySelection(
    req: Request,
    submissionID: String,
    setupID: String,
    userID: UUID
) async throws -> Data {
    guard let submission = try await APISubmission.find(submissionID, on: req.db) else {
        throw Abort(.notFound, reason: "Submission not found")
    }
    guard submission.kind == APISubmission.Kind.student else {
        throw Abort(.forbidden)
    }
    guard submission.userID == userID else {
        throw Abort(.forbidden)
    }
    guard submission.testSetupID == setupID else {
        throw Abort(.badRequest, reason: "Submission does not belong to this assignment")
    }

    let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
    let nameExt = (submission.filename ?? "").lowercased()
    guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
        throw Abort(.badRequest, reason: "Only notebook submissions can be opened in notebook view")
    }

    let dataURL = URL(fileURLWithPath: submission.zipPath)
    guard let data = try? Data(contentsOf: dataURL),
          (try? JSONSerialization.jsonObject(with: data)) != nil else {
        throw Abort(.notFound, reason: "Notebook artifact is unavailable for this submission")
    }
    return normalizeNotebookForJupyterLite(data)
}

private func removeLegacyUserNotebookCopies(req: Request, userID: UUID) {
    let userSlug = userID.uuidString.lowercased()
    let roots = [
        req.application.directory.publicDirectory + "files/",
        req.application.directory.publicDirectory + "jupyterlite/files/",
        req.application.directory.publicDirectory + "jupyterlite/lab/files/",
        req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
    ]

    let fileManager = FileManager.default
    for root in roots {
        let userDir = root + "users/\(userSlug)/"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: userDir) else { continue }

        for name in entries {
            let path = userDir + name
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            guard URL(fileURLWithPath: name).pathExtension.lowercased() == "ipynb" else {
                continue
            }
            let lower = name.lowercased()
            let shouldRemove = lower == "assignment.ipynb"
                || lower == "submission.ipynb"
                || (lower.hasPrefix("sub_") && lower.hasSuffix(".ipynb"))
            guard shouldRemove else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }
}

private func latestNotebookSubmissionData(
    req: Request,
    setupID: String,
    userID: UUID,
    fallbackSetup: APITestSetup
) async throws -> (data: Data, filename: String?) {
    let submissions = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$userID == userID)
        .filter(\.$kind == APISubmission.Kind.student)
        .sort(\.$submittedAt, .descending)
        .all()

    for submission in submissions {
        let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
        let nameExt = (submission.filename ?? "").lowercased()
        guard pathExt == "ipynb" || nameExt.hasSuffix(".ipynb") else {
            continue
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: submission.zipPath)),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            continue
        }
        return (data, submission.filename)
    }

    let fallbackFilename: String? = {
        guard let path = fallbackSetup.notebookPath, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()
    return (try notebookData(for: fallbackSetup), fallbackFilename)
}

/// Detects the dependency-skip message format and extracts the blocking test name.
/// Matches: `Skipped: prerequisite 'test_build.py' did not pass`
private func parseSkip(shortResult: String) -> (isSkipped: Bool, blockerName: String?) {
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

private func stderrScriptOutput(from raw: String?, status: TestStatus) -> String? {
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

private func extractLabeledOutputSection(_ label: String, in text: String) -> String? {
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

// MARK: - Multipart body for code submission

private struct SubmitFormBody: Content {
    var files: Data
    /// Original filename from the browser's multipart upload (nil for older clients).
    var uploadFilename: String?
}

private func inferredRawSubmissionExtension(data: Data, uploadFilename: String?) -> String {
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
