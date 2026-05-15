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

import Core
import Fluent
import Foundation
import Leaf
import Vapor

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

        // If the user has no active enrollment but open-mode courses exist → redirect to /enroll.
        // We only redirect when self-enrolment is actually possible; if all courses are closed
        // or auto the /enroll page would be empty and the redirect would be confusing.
        if courseState.active == nil {
            let openCourseCount = try await APICourse.query(on: req.db)
                .filter(\.$isArchived == false)
                .filter(\.$enrollmentModeRaw == CourseEnrollmentMode.open.rawValue)
                .count()
            if openCourseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        let fmt = waterlooDateTimeFormatter()

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
                return try await req.view.render(
                    "index",
                    IndexContext(
                        sections: [], ungroupedSetups: [], hasSections: false, hasUngrouped: false,
                        currentUser: userContext)
                ).encodeResponse(for: req)
            }
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ publishedIDs)
                .sort(\.$createdAt, .descending)
                .all()
        }

        var latestSubmissionBySetupID: [String: LatestSubmissionItem] = [:]
        var submissionCountBySetupID: [String: Int] = [:]
        var bestGradePercentBySetupID: [String: Int] = [:]
        var latestBadgesBySetupID: [String: [AchievementBadge]] = [:]
        // Per-user active extensions for the current user, keyed by
        // testSetupID (since the dashboard works in setup space; we look
        // up the assignment for each row separately).
        var extensionDueAtBySetupID: [String: Date] = [:]
        if let userID = user.id, !allAssignments.isEmpty {
            let assignmentIDs = allAssignments.compactMap(\.id)
            let extensions = try await APIAssignmentExtension.query(on: req.db)
                .filter(\.$assignmentID ~~ Set(assignmentIDs))
                .filter(\.$userID == userID)
                .all()
            let setupIDByAssignmentID = Dictionary(
                uniqueKeysWithValues: allAssignments.compactMap { a -> (UUID, String)? in
                    guard let id = a.id else { return nil }
                    return (id, a.testSetupID)
                }
            )
            for row in extensions {
                guard let setupID = setupIDByAssignmentID[row.assignmentID] else { continue }
                extensionDueAtBySetupID[setupID] = row.extendedDueAt
            }
        }
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
                            let gradePercent = gradePercentFromCollectionJSON(result.collectionJSON)
                        else {
                            continue
                        }
                        let setupID = submission.testSetupID
                        let existing = bestGradePercentBySetupID[setupID] ?? 0
                        if gradePercent > existing {
                            bestGradePercentBySetupID[setupID] = gradePercent
                        }
                    }

                    for (setupID, latest) in latestSubmissionBySetupID {
                        guard let latestSubmission = grouped[setupID]?.first(where: { $0.id == latest.submissionID }),
                            let result = preferredResultBySubmissionID[latest.submissionID],
                            let assignment = assignmentBySetup[setupID],
                            let collection = visibleCollection(
                                from: result.collectionJSON,
                                for: user,
                                assignment: assignment
                            ),
                            let gradePercent = gradePercent(from: collection)
                        else {
                            continue
                        }
                        let latestAttempt = latestSubmission.attemptNumber ?? 1
                        let priorSub = grouped[setupID]?.first(where: { $0.attemptNumber == latestAttempt - 1 })
                        let priorGradePercent: Int? = priorSub.flatMap { ps in
                            guard let psID = ps.id,
                                let pr = preferredResultBySubmissionID[psID]
                            else { return nil }
                            return gradePercentFromCollectionJSON(pr.collectionJSON)
                        }
                        latestBadgesBySetupID[setupID] = AchievementBadge.forSubmission(
                            BadgeContext(
                                attemptNumber: latestAttempt,
                                gradePercent: gradePercent,
                                executionTimeMs: collection.executionTimeMs,
                                priorGradePercent: priorGradePercent
                            ))
                    }

                    // Batch-query class-wide badges this user currently holds across all setups.
                    let classAchievements = try await APIClassAchievement.query(on: req.db)
                        .filter(\.$userID == userID)
                        .filter(\.$testSetupID ~~ setupIDs)
                        .all()
                    for ach in classAchievements {
                        if let badge = AchievementBadge.forClassAchievement(ach.achievementID) {
                            latestBadgesBySetupID[ach.testSetupID, default: []].append(badge)
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
            case (let l?, let r?) where l != r:
                return l < r
            default:
                let lhsCreated = lhs.createdAt ?? .distantPast
                let rhsCreated = rhs.createdAt ?? .distantPast
                if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
                return lhsID < rhsID
            }
        }

        let rows = sortedSetups.map { setup -> TestSetupRow in
            let setupID = setup.id ?? ""
            let data = Data(setup.manifest.utf8)
            let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            let assignment = assignmentBySetup[setupID]
            let latestSubmission = latestSubmissionBySetupID[setupID]
            let submissionCount = submissionCountBySetupID[setupID] ?? 0
            let status: String
            if let assignment {
                status = assignment.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }
            let hasNotebook: Bool = {
                // True when the setup has a flat notebook file on disk, or the zip
                // contains at least one .ipynb entry.
                if let path = setup.notebookPath, !path.isEmpty,
                    FileManager.default.fileExists(atPath: path)
                {
                    return true
                }
                return listZipEntries(zipPath: setup.zipPath)
                    .contains { $0.hasSuffix(".ipynb") }
            }()
            let vanityBaseURL: String? = {
                guard let assignment,
                    let courseCode = courseState.active?.code,
                    !courseCode.isEmpty,
                    !assignment.slug.isEmpty
                else { return nil }
                return VanityURLRoutes.vanityPath(courseCode: courseCode, assignmentSlug: assignment.slug)
            }()
            // Active extension for this student on this assignment.  Drives
            // the Submit button and Due column when the assignment-wide
            // deadline has passed but this user retains submit privileges.
            let extensionDueAt = extensionDueAtBySetupID[setupID]
            let baselineDueAt = assignment?.dueAt
            let hasActiveExtension: Bool = {
                guard let extDate = extensionDueAt else { return false }
                if let baseline = baselineDueAt, extDate <= baseline { return false }
                return Date() < extDate
            }()
            let isOpenForThisUser: Bool = {
                guard let assignment else { return false }
                if !assignment.isOpen { return false }
                if let dueAt = assignment.dueAt, dueAt <= Date() {
                    if assignment.deadlineOverrideActive == true { return true }
                    return hasActiveExtension
                }
                return true
            }()
            let effectiveDueAt: Date? = {
                guard let extDate = extensionDueAt else { return baselineDueAt }
                guard let baseline = baselineDueAt else { return extDate }
                return max(extDate, baseline)
            }()
            return TestSetupRow(
                id: setupID,
                title: assignment?.title,
                notebookURL: vanityBaseURL ?? "/testsetups/\(setupID)/notebook",
                submitURL: vanityBaseURL.map { "\($0)/submit" } ?? "/testsetups/\(setupID)/submit",
                historyURL: vanityBaseURL.map { "\($0)/history" } ?? "/testsetups/\(setupID)/history",
                suiteCount: props?.testSuites.count ?? 0,
                createdAt: setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                dueAt: assignment?.dueAt.map { fmt.string(from: $0) },
                status: status,
                isOpen: isOpenForThisUser,
                gradingMode: props?.gradingMode.rawValue ?? GradingMode.worker.rawValue,
                hasNotebook: hasNotebook,
                submissionCount: submissionCount,
                hasLatestSubmission: latestSubmission != nil,
                latestSubmissionID: latestSubmission?.submissionID ?? "",
                latestSubmittedAtText: latestSubmission?.submittedAtText ?? "—",
                additionalSubmissionCount: max(submissionCount - 1, 0),
                bestGradeText: bestGradePercentBySetupID[setupID].map { "\($0)%" },
                badges: latestBadgesBySetupID[setupID] ?? [],
                hasActiveExtension: hasActiveExtension,
                effectiveDueAtText: effectiveDueAt.map { fmt.string(from: $0) }
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

        return try await req.view.render(
            "index",
            IndexContext(
                sections: sectionContexts,
                ungroupedSetups: ungroupedSetups,
                hasSections: !allSections.isEmpty,
                hasUngrouped: !ungroupedSetups.isEmpty,
                currentUser: userContext
            )
        ).encodeResponse(for: req)
    }

    // MARK: - GET /testsetups/new

    @Sendable
    func newSetupForm(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }
        return try await req.view.render(
            "setup-new",
            BaseContext(currentUser: req.currentUserContext))
    }

    // MARK: - POST /testsetups/new

    @Sendable
    func createSetup(req: Request) async throws -> Response {
        let setupUser = try req.auth.require(APIUser.self)
        guard setupUser.isInstructor else { throw Abort(.forbidden) }
        let upload = try req.content.decode(TestSetupUpload.self)

        let manifestData = Data(upload.manifest.utf8)
        let manifest: TestProperties
        do {
            manifest = try ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        } catch {
            throw Abort(.badRequest, reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw Abort(.badRequest, reason: "Unsupported schemaVersion; expected 1")
        }

        let setupsDir = req.application.testSetupsDirectory
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = setupsDir + "\(setupID).zip"
        try upload.files.write(to: URL(fileURLWithPath: zipPath))

        let stored = String(data: try ManifestCodec.encoder.encode(manifest), encoding: .utf8) ?? upload.manifest

        // Associate the setup with the instructor's active course.
        let courseState = try await req.resolveActiveCourse(for: setupUser)
        guard let courseID = courseState.activeCourseUUID else {
            throw Abort(
                .badRequest, reason: "No active course selected. Please select a course before uploading a test setup.")
        }
        let setup = APITestSetup(
            id: setupID, manifest: stored, zipPath: zipPath,
            courseID: courseID)
        try await setup.save(on: req.db)

        return req.redirect(to: "/")
    }

}
