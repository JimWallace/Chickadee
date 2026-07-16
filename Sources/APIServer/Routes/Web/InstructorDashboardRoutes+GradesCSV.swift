// APIServer/Routes/Web/InstructorDashboardRoutes+GradesCSV.swift
//
// The instructor grades CSV export (GET /instructor/grades.csv) and its
// load/sort/render helpers.  Split out of
// InstructorDashboardRoutes+Submissions.swift — no behaviour changes.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/grades.csv

    @Sendable
    func exportGradesCSV(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        // Phase 1: students + assignments in parallel.  Both only need
        // `activeCourseUUID`; neither depends on the other.
        async let studentsFuture = loadGradesCSVStudents(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        async let assignmentsFuture = loadGradesCSVAssignments(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        let students = try await studentsFuture
        let assignments = try await assignmentsFuture

        let setupIDs = Set(assignments.map(\.testSetupID))
        let studentIDs = Set(students.compactMap(\.id))

        // Phase 2: setups-by-id + submissions in parallel.  Both depend on
        // phase 1 (setupIDs / studentIDs), but neither depends on the other.
        async let setupByIDFuture = loadGradesCSVSetupsByID(req: req, setupIDs: setupIDs)
        async let submissionsFuture = loadGradesCSVSubmissions(
            req: req, setupIDs: setupIDs, studentIDs: studentIDs)
        let setupByID = try await setupByIDFuture
        let submissions = try await submissionsFuture

        let sortedAssignments = sortedByAssignmentDisplayOrder(assignments, setupsByID: setupByID)
        let submissionIDs = submissions.map(\.id)

        // Serial follow-on: needs submission IDs from phase 2.
        // Load every result for every submission (not just the worker-preferred one)
        // so that "highest grade wins" — a 100 % browser run is never displaced by
        // a later worker regrading at a lower percentage.  The best percentage is
        // then converted to points using the manifest total so the CSV column is
        // anchored to a stable scale regardless of which tier mix each result used.
        let allResultsBySubmission = try await gradeSummariesBySubmissionID(
            for: submissionIDs, on: req.db)
        var bestPointsByUserAndSetup = bestGradePointsByUserAndSetup(
            submissions: submissions,
            allResultsBySubmission: allResultsBySubmission,
            setupByID: setupByID
        )

        // Instructor grade overrides replace the runner-computed points. They
        // apply even when the student has no submission, so this overlays the
        // map rather than filtering within it. The override percent is
        // converted to points against the setup's total possible points.
        let overrideMap = try await loadGradeOverridePercents(setupIDs: setupIDs, on: req.db)
        var overrideKeys: Set<String> = []
        for (key, pct) in overrideMap {
            guard let setup = setupByID[key.setupID],
                let points = gradeOverridePoints(percent: pct, setup: setup)
            else { continue }
            let mapKey = "\(key.userID.uuidString.lowercased())::\(key.setupID)"
            bestPointsByUserAndSetup[mapKey] = points
            overrideKeys.insert(mapKey)
        }

        // Class-goal bonus: extra credit (capped at 100%) for every graded
        // submission on a setup with class goals.  Overrides are authoritative,
        // so a key an override already set is left untouched.
        for setupID in setupIDs {
            guard let setup = setupByID[setupID] else { continue }
            let props = setup.decodedManifest()
            let bonus = try await classGoalBonusPoints(
                testSetupID: setupID, props: props, on: req.db)
            guard bonus > 0, let total = suiteTotalPoints(props: props)
            else { continue }
            let suffix = "::\(setupID)"
            for (mapKey, points) in bestPointsByUserAndSetup
            where mapKey.hasSuffix(suffix) && !overrideKeys.contains(mapKey) {
                bestPointsByUserAndSetup[mapKey] = min(total, points + bonus)
            }
        }

        let csv = renderGradesCSV(
            students: students,
            sortedAssignments: sortedAssignments,
            bestPointsByUserAndSetup: bestPointsByUserAndSetup
        )

        let timestamp = Int(Date().timeIntervalSince1970)
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/csv; charset=utf-8")
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"grades-\(timestamp).csv\""
        )
        response.body = .init(string: csv)
        return response
    }

    // MARK: - exportGradesCSV helpers

    /// Only include students enrolled in the active course (if one is set).
    private func loadGradesCSVStudents(
        req: Request, activeCourseUUID: UUID?
    ) async throws -> [APIUser] {
        if let activeCourseUUID {
            // Students are `.student`-role enrollments now (#417 Slice G2).
            let studentUserIDs = try await studentUserIDsInCourse(activeCourseUUID, on: req.db)
            guard !studentUserIDs.isEmpty else { return [] }
            return try await APIUser.query(on: req.db)
                .filter(\.$id ~~ Array(studentUserIDs))
                .sort(\.$username, .ascending)
                .all()
        }
        // No active course: every student across the deployment — the union of
        // all `.student`-role enrollments (#417 Slice G2; the global role no
        // longer distinguishes students). Filtered DB-side (#1160): the
        // unscoped fetch grows with every past term. NULL role means
        // pre-migration student (the computed `role` accessor's default), so
        // the predicate must keep NULL rows.
        let studentEnrollments = try await APICourseEnrollment.query(on: req.db)
            .group(.or) { or in
                or.filter(\.$roleRaw == CourseRole.student.rawValue)
                or.filter(\.$roleRaw == .null)
            }
            .field(\.$userID)
            .all()
        let studentUserIDs = Set(studentEnrollments.map(\.userID))
        guard !studentUserIDs.isEmpty else { return [] }
        return try await APIUser.query(on: req.db)
            .filter(\.$id ~~ Array(studentUserIDs))
            .sort(\.$username, .ascending)
            .all()
    }

    private func loadGradesCSVAssignments(
        req: Request, activeCourseUUID: UUID?
    ) async throws -> [APIAssignment] {
        if let activeCourseUUID {
            return try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .all()
        }
        return try await APIAssignment.query(on: req.db).all()
    }

    private func loadGradesCSVSetupsByID(
        req: Request, setupIDs: Set<String>
    ) async throws -> [String: APITestSetup] {
        let setups =
            setupIDs.isEmpty
            ? []
            : try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ setupIDs)
                .all()
        return Dictionary(
            uniqueKeysWithValues: setups.compactMap { setup in
                setup.id.map { ($0, setup) }
            })
    }

    private func loadGradesCSVSubmissions(
        req: Request,
        setupIDs: Set<String>,
        studentIDs: Set<UUID>
    ) async throws -> [(id: String, userID: UUID, setupID: String)] {
        let submissionRows =
            (setupIDs.isEmpty || studentIDs.isEmpty)
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$userID ~~ studentIDs)
                .all()
        return submissionRows.compactMap { row -> (id: String, userID: UUID, setupID: String)? in
            guard let id = row.id, let userID = row.userID else { return nil }
            return (id, userID, row.testSetupID)
        }
    }

    // The grouped result loader moved to the shared helper file
    // (`allResultsBySubmissionID`, BestGradePercentBySubmissionID.swift) so
    // this file and the highest-grade fold can't drift apart (#1111).

    /// Returns the best earned points per (user, setup), where "best" is the
    /// highest grade percentage achieved across ALL results for ALL submissions
    /// (browser and worker alike), converted to points via the manifest total.
    ///
    /// Using percentage × manifest-total rather than raw earnedPoints means the
    /// CSV column is on a stable scale: the instructor knows exactly what LEARN
    /// max to enter (the manifest total), and a 100 % browser result is never
    /// overwritten by a lower-percentage worker result from a later regrading.
    private func bestGradePointsByUserAndSetup(
        submissions: [(id: String, userID: UUID, setupID: String)],
        allResultsBySubmission: [String: [GradeResultSummary]],
        setupByID: [String: APITestSetup]
    ) -> [String: Double] {
        // Step 1: highest grade percentage across ALL results for ALL
        // submissions — the shared "highest grade wins" fold (#1111).
        var bestPctByKey: [String: Int] = [:]
        for submission in submissions {
            let key = "\(submission.userID.uuidString.lowercased())::\(submission.setupID)"
            guard let pct = bestGradePercent(of: allResultsBySubmission[submission.id] ?? [])
            else { continue }
            if pct > (bestPctByKey[key] ?? -1) { bestPctByKey[key] = pct }
        }
        // Step 2: convert best percentage → points anchored to the manifest total.
        var best: [String: Double] = [:]
        for (key, pct) in bestPctByKey {
            guard let setupID = key.components(separatedBy: "::").last,
                let setup = setupByID[setupID],
                let total = suiteTotalPoints(props: setup.decodedManifest())
            else { continue }
            best[key] = Double(pct) / 100.0 * total
        }
        return best
    }

    private func renderGradesCSV(
        students: [APIUser],
        sortedAssignments: [APIAssignment],
        bestPointsByUserAndSetup: [String: Double]
    ) -> String {
        var lines: [String] = []
        let header =
            ["OrgDefinedId", "Username"]
            + sortedAssignments.map { "\($0.title) Points Grade" }
            + ["End-of-Line Indicator"]
        lines.append(header.map(csvEscaped).joined(separator: ","))

        for student in students {
            guard let userID = student.id else { continue }
            var row: [String] = [student.studentID ?? "", "#\(student.username)"]
            for assignment in sortedAssignments {
                let key = "\(userID.uuidString.lowercased())::\(assignment.testSetupID)"
                if let points = bestPointsByUserAndSetup[key] {
                    row.append(String(format: "%.1f", points))
                } else {
                    row.append("")
                }
            }
            row.append("#")
            lines.append(row.map(csvEscaped).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
