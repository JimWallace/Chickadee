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
        routes.post("testsetups", ":testSetupID", "reset-notebook", use: resetOwnNotebook)
        routes.get("submissions", ":submissionID", use: submissionPage)
    }

    // MARK: - GET /

    // The student dashboard handler dispatches across many distinct
    // page states: no active course → /enroll, instructor-only courses
    // → admin index, no assignments yet → empty-course page, etc.  Each
    // arm builds a different Leaf context with disjoint data needs, so
    // splitting them would require either a state-machine wrapper or
    // duplicating the auth + course resolution preamble at each arm's
    // entry point.  Both are noisier than the inline switch.
    @Sendable
    // swiftlint:disable:next function_body_length cyclomatic_complexity
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
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // The three independent reads that key off the assignment list run
        // concurrently (helpers in WebRoutes+IndexLoading.swift): per-user
        // extensions, prior engagement (keeps closed assignments visible),
        // and the course sections used to group rows at the bottom of the
        // page.
        async let extensionsFetch = Self.loadExtensionDueDates(
            user: user, allAssignments: allAssignments, db: req.db)
        async let previouslyOpenedFetch = Self.loadPreviouslyOpenedSetupIDs(
            user: user, allAssignments: allAssignments, db: req.db)
        async let sectionsFetch = Self.loadCourseSections(
            activeCourseUUID: courseState.activeCourseUUID, db: req.db)

        let extensionDueAtBySetupID = try await extensionsFetch
        let previouslyOpenedSetupIDs = try await previouslyOpenedFetch

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
            // Enrolled students see every published assignment in their course:
            // open ones, and ones that were published and have since closed at
            // their deadline — kept on the list (read-only) so recent labs never
            // silently disappear. Preview / scheduled / unpublished-draft
            // assignments stay hidden (see assignmentVisibleToStudentByState).
            let now = Date()
            var visibleSetupIDs = Set(
                allAssignments
                    .filter { assignmentVisibleToStudentByState($0, now: now) }
                    .map(\.testSetupID))
            // An active per-student extension also reveals an assignment that was
            // closed before its deadline (which the by-state rule leaves hidden
            // for everyone else) to the one student who was granted more time.
            for (setupID, extendedDueAt) in extensionDueAtBySetupID
            where studentHasActiveExtension(extensionDueAt: extendedDueAt, now: now) {
                visibleSetupIDs.insert(setupID)
            }
            // Any closed assignment the student already engaged with stays listed
            // too — covers no-deadline assignments the by-state rule can't classify.
            visibleSetupIDs.formUnion(previouslyOpenedSetupIDs)
            guard !visibleSetupIDs.isEmpty else {
                return try await req.view.render(
                    "index",
                    IndexContext(displayGroups: [], hasAny: false, currentUser: userContext)
                ).encodeResponse(for: req)
            }
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ visibleSetupIDs)
                .sort(\.$createdAt, .descending)
                .all()
        }

        var latestSubmissionBySetupID: [String: LatestSubmissionItem] = [:]
        var submissionCountBySetupID: [String: Int] = [:]
        var bestGradePercentBySetupID: [String: Int] = [:]
        var overridePercentBySetupID: [String: Int] = [:]
        var latestBadgesBySetupID: [String: [AchievementBadge]] = [:]
        if let userID = user.id {
            let setupIDs = setups.compactMap(\.id)
            if !setupIDs.isEmpty {
                // Instructor grade overrides for this student take precedence
                // over the runner-computed best grade below.  The override and
                // submission reads are independent and run concurrently.
                async let overridesFetch = loadGradeOverridePercents(setupIDs: setupIDs, on: req.db)
                async let submissionsFetch = APISubmission.query(on: req.db)
                    .filter(\.$userID == userID)
                    .filter(\.$testSetupID ~~ setupIDs)
                    .filter(\.$kind == APISubmission.Kind.student)
                    .sort(\.$submittedAt, .descending)
                    .all()
                let overrideMap = try await overridesFetch
                for setupID in setupIDs {
                    if let pct = overrideMap[GradeOverrideKey(setupID: setupID, userID: userID)] {
                        overridePercentBySetupID[setupID] = pct
                    }
                }
                let submissions = try await submissionsFetch

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
                    // Results plus the three achievement reads only share
                    // inputs computed above, so all four run concurrently.
                    async let resultsFetch = APIResult.query(on: req.db)
                        .filter(\.$submissionID ~~ submissionIDs)
                        .sort(\.$receivedAt, .descending)
                        .all()
                    async let disabledFetch = BuiltInAchievements.disabledBySetup(
                        setupIDs: Array(setupIDs), on: req.db)
                    async let perSubFetch = BuiltInAchievements.manifestPerSubmissionBySetup(
                        setupIDs: Array(setupIDs), on: req.db)
                    // Class-wide badges this user currently holds across all setups.
                    async let classAchievementsFetch = APIClassAchievement.query(on: req.db)
                        .filter(\.$userID == userID)
                        .filter(\.$testSetupID ~~ setupIDs)
                        .all()
                    let resultRows = try await resultsFetch

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
                            let gradePercent = result.gradePercentValue
                        else {
                            continue
                        }
                        let setupID = submission.testSetupID
                        let existing = bestGradePercentBySetupID[setupID] ?? 0
                        if gradePercent > existing {
                            bestGradePercentBySetupID[setupID] = gradePercent
                        }
                    }

                    let disabledBySetup = try await disabledFetch
                    let perSubBySetup = try await perSubFetch
                    for (setupID, latest) in latestSubmissionBySetupID {
                        guard let latestSubmission = grouped[setupID]?.first(where: { $0.id == latest.submissionID }),
                            let result = preferredResultBySubmissionID[latest.submissionID],
                            let collection = decodedCollection(from: result.collectionJSON),
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
                            return pr.gradePercentValue
                        }
                        latestBadgesBySetupID[setupID] = AchievementBadge.forSubmission(
                            BadgeContext(
                                attemptNumber: latestAttempt,
                                gradePercent: gradePercent,
                                executionTimeMs: collection.executionTimeMs,
                                priorGradePercent: priorGradePercent
                            ),
                            achievements: perSubBySetup[setupID],
                            disabled: disabledBySetup[setupID] ?? [])
                    }

                    let classAchievements = try await classAchievementsFetch
                    for ach in classAchievements {
                        if let badge = AchievementBadge.forClassAchievement(
                            ach.achievementID, disabled: disabledBySetup[ach.testSetupID] ?? [])
                        {
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

        // Notebook presence drives the Edit button.  The zip-derived answer
        // costs an `unzip` subprocess per setup, so it is resolved through
        // NotebookPresenceCache (keyed by zip mtime + size) instead of being
        // recomputed on every dashboard view.
        var hasNotebookBySetupID: [String: Bool] = [:]
        for setup in sortedSetups {
            let setupID = setup.id ?? ""
            if let path = setup.notebookPath, !path.isEmpty,
                FileManager.default.fileExists(atPath: path)
            {
                hasNotebookBySetupID[setupID] = true
            } else {
                hasNotebookBySetupID[setupID] = await req.application.notebookPresenceCache
                    .zipContainsNotebook(zipPath: setup.zipPath)
            }
        }

        let rows = sortedSetups.map { setup -> TestSetupRow in
            let setupID = setup.id ?? ""
            let data = Data(setup.manifest.utf8)
            let props = decodeManifest(from: data)
            let assignment = assignmentBySetup[setupID]
            let latestSubmission = latestSubmissionBySetupID[setupID]
            let submissionCount = submissionCountBySetupID[setupID] ?? 0
            // A future open date drives the "Opens …" hint in the Due column,
            // but not a distinct status — every assignment is scheduled, so a
            // "scheduled" badge would add no signal.
            let notYetOpen: Bool = {
                guard let assignment, let startsAt = assignment.startsAt else { return false }
                return Date() < startsAt
            }()
            // Preview is staff-only: staff see it functioning as "open" with a
            // subtle staff-only marker, while to students it is indistinguishable
            // from "closed". So the displayed status is resolved per viewer.
            let status: String
            let staffOnly: Bool
            if let assignment {
                switch assignment.visibility {
                case .open:
                    status = "open"
                    staffOnly = false
                case .closed:
                    status = "closed"
                    staffOnly = false
                case .preview:
                    status = user.isInstructor ? "open" : "closed"
                    staffOnly = user.isInstructor
                }
            } else {
                status = "unpublished"
                staffOnly = false
            }
            // True when the setup has a flat notebook file on disk, or the zip
            // contains at least one .ipynb entry (resolved above via the cache).
            let hasNotebook = hasNotebookBySetupID[setupID] ?? false
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
            let hasActiveExtension = studentHasActiveExtension(extensionDueAt: extensionDueAt)
            let effectiveDueAt = laterDeadline(
                baseline: baselineDueAt, extensionDueAt: extensionDueAt)
            let isOpenForThisUser: Bool = {
                guard let assignment else { return false }
                // Preview is open for staff, closed for students; staff testing a
                // preview also bypass the future-open-date gate (see submissionGate).
                let gate = assignment.visibility.submissionGate(isStaff: user.isInstructor)
                return isAssignmentOpenForUser(
                    isOpen: gate.treatAsOpen,
                    overrideActive: assignment.deadlineOverrideActive ?? false,
                    baselineDueAt: baselineDueAt,
                    effectiveDueAt: effectiveDueAt,
                    hasActiveExtension: hasActiveExtension,
                    startsAt: gate.honorsStartDate ? assignment.startsAt : nil
                )
            }()
            // A published-but-closed assignment is openable read-only, so it
            // still gets the open-notebook action even for a student who never
            // engaged with it (the page renders read-only and hides Submit).
            let canEdit =
                isOpenForThisUser
                || previouslyOpenedSetupIDs.contains(setupID)
                || (assignment.map { assignmentVisibleToStudentByState($0) } ?? false)
            let badgeSplit = AchievementBadge.dashboardSplit(latestBadgesBySetupID[setupID] ?? [])
            return TestSetupRow(
                id: setupID,
                title: assignment?.title,
                notebookURL: vanityBaseURL ?? "/testsetups/\(setupID)/notebook",
                submitURL: vanityBaseURL.map { "\($0)/submit" } ?? "/testsetups/\(setupID)/submit",
                historyURL: vanityBaseURL.map { "\($0)/history" } ?? "/testsetups/\(setupID)/history",
                suiteCount: props?.testSuites.count ?? 0,
                createdAt: setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                dueAt: assignment?.dueAt.map { fmt.string(from: $0) },
                opensAtText: notYetOpen ? assignment?.startsAt.map { fmt.string(from: $0) } : nil,
                status: status,
                staffOnly: staffOnly,
                isOpen: isOpenForThisUser,
                canEdit: canEdit,
                gradingMode: props?.gradingMode.rawValue ?? GradingMode.worker.rawValue,
                hasNotebook: hasNotebook,
                submissionCount: submissionCount,
                hasLatestSubmission: latestSubmission != nil,
                latestSubmissionID: latestSubmission?.submissionID ?? "",
                latestSubmittedAtText: latestSubmission?.submittedAtText ?? "—",
                additionalSubmissionCount: max(submissionCount - 1, 0),
                bestGradeText: overridePercentBySetupID[setupID].map { "\($0)%" }
                    ?? bestGradePercentBySetupID[setupID].map { "\($0)%" },
                gradeIsOverridden: overridePercentBySetupID[setupID] != nil,
                badges: badgeSplit.visible,
                extraBadgeCount: badgeSplit.extraCount,
                extraBadgesTooltip: badgeSplit.extraTooltip,
                hasActiveExtension: hasActiveExtension,
                effectiveDueAtText: effectiveDueAt.map { fmt.string(from: $0) }
            )
        }

        // Sections for the active course (fetch started up top) enable the
        // grouped display below.
        let allSections = try await sectionsFetch

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

        // Build the ordered display groups: named sections (skipping any with no
        // visible items) first, then a trailing unnamed bucket for ungrouped items.
        var displayGroups: [IndexDisplayGroup] = allSections.compactMap { section in
            guard let sID = section.id else { return nil }
            let sectionRows = rowsBySectionID[sID] ?? []
            guard !sectionRows.isEmpty else { return nil }
            return IndexDisplayGroup(name: section.name, setups: sectionRows)
        }
        if !ungroupedSetups.isEmpty {
            displayGroups.append(IndexDisplayGroup(name: nil, setups: ungroupedSetups))
        }

        return try await req.view.render(
            "index",
            IndexContext(
                displayGroups: displayGroups,
                hasAny: !displayGroups.isEmpty,
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
            throw AppError.unprocessable(reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw AppError.unprocessable(reason: "Unsupported schemaVersion; expected 1")
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
