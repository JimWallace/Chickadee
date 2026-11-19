// APIServer/Routes/Web/InstructorDashboardRoutes+GradesCSV.swift
//
// The instructor grades CSV export (GET /instructor/grades.csv) and its
// load/sort/render helpers.  Split out of
// InstructorDashboardRoutes+Submissions.swift — no behaviour changes.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/grades.csv

    @Sendable
    func exportGradesCSV(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        // Phase 1: students + assignments + sections in parallel.  All only need
        // `activeCourseUUID`; none depends on the others.
        async let studentsFuture = loadGradesCSVStudents(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        async let assignmentsFuture = loadGradesCSVAssignments(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        async let sectionsFuture = loadCourseSections(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        let students = try await studentsFuture
        let assignments = try await assignmentsFuture
        let sections = try await sectionsFuture

        let setupIDs = Set(assignments.map(\.testSetupID))
        let studentIDs = Set(students.map(\.id))

        // Phase 2: setups-by-id + best grades in parallel.  Both depend on
        // phase 1 (setupIDs / studentIDs), but neither depends on the other.
        //
        // "Highest grade wins" across EVERY result of every submission (not
        // just the worker-preferred one), so a 100 % browser run is never
        // displaced by a later worker regrading at a lower percentage. The
        // fold runs in the database and returns one row per (student,
        // assignment): hydrating every submission and result of the course
        // took seconds on the event loop at one course's scale
        // (docs/database-performance.md).
        async let setupByIDFuture = loadGradesCSVSetupsByID(req: req, setupIDs: setupIDs)
        async let bestPercentFuture = bestGradePercentByStudentAndSetup(
            setupIDs: Array(setupIDs), studentIDs: Array(studentIDs), on: req.db)
        let setupByID = try await setupByIDFuture
        let bestPercentByKey = try await bestPercentFuture

        // Section-aware column order: assignments group by their section's
        // display order (ungrouped last), then by the shared per-section item
        // order within each group — deterministic even though `sort_order` is
        // now only unique per (course, section), not course-globally.
        let sectionSortByID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: sections.compactMap { s in s.id.map { ($0, s.sortOrder) } })
        let sortedAssignments = assignments.sorted { lhs, rhs in
            let lhsSection = lhs.sectionID.flatMap { sectionSortByID[$0] } ?? Int.max
            let rhsSection = rhs.sectionID.flatMap { sectionSortByID[$0] } ?? Int.max
            if lhsSection != rhsSection { return lhsSection < rhsSection }
            return assignmentDisplayOrderPrecedes(
                lhsSortOrder: lhs.sortOrder, rhsSortOrder: rhs.sortOrder,
                lhsCreatedAt: setupByID[lhs.testSetupID]?.createdAt,
                rhsCreatedAt: setupByID[rhs.testSetupID]?.createdAt,
                lhsSetupID: lhs.testSetupID, rhsSetupID: rhs.testSetupID)
        }
        // The best percentage is converted to points using the manifest total
        // so the CSV column is anchored to a stable scale regardless of which
        // tier mix each result used.
        var bestPointsByUserAndSetup = bestGradePointsByUserAndSetup(
            bestPercentByKey: bestPercentByKey, setupByID: setupByID)

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

        // Class-goal bonus: true extra credit for every graded submission on a
        // setup with class goals — it may take a student above the suite total.
        // Overrides are authoritative, so a key an override already set is left
        // untouched. On an activity that runs per lab group, each student
        // earns their own lab's bonus (docs/lab-groups.md, slice 5).
        let assignmentBySetup = Dictionary(
            assignments.map { ($0.testSetupID, $0) }, uniquingKeysWith: { first, _ in first })
        for setupID in setupIDs {
            guard let setup = setupByID[setupID], let assignment = assignmentBySetup[setupID] else { continue }
            let props = setup.decodedManifest()
            guard let bonus = try await ClassGoalBonusTable.load(assignment: assignment, props: props, on: req.db),
                let total = suiteTotalPoints(props: props)
            else { continue }
            let suffix = "::\(setupID)"
            for (mapKey, points) in bestPointsByUserAndSetup
            where mapKey.hasSuffix(suffix) && !overrideKeys.contains(mapKey) {
                guard let userID = UUID(uuidString: String(mapKey.dropLast(suffix.count))) else { continue }
                bestPointsByUserAndSetup[mapKey] = earnedWithClassGoalBonus(
                    earned: points, total: total, bonus: bonus.points(for: userID))
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

    /// One roster row of the export: the three columns it writes. A plain
    /// value, not a Fluent model.
    struct GradesCSVStudent: Sendable {
        let id: UUID
        let username: String
        let studentID: String?
    }

    /// Only include students enrolled in the active course (if one is set).
    private func loadGradesCSVStudents(
        req: Request, activeCourseUUID: UUID?
    ) async throws -> [GradesCSVStudent] {
        if let activeCourseUUID {
            // Students are `.student`-role enrollments now (#417 Slice G2).
            let studentUserIDs = try await CourseRoster.studentIDs(in: activeCourseUUID, on: req.db)
            return try await loadGradesCSVStudentRows(ids: Array(studentUserIDs), on: req.db)
        }
        // No active course: every student across the deployment — the union of
        // all `.student`-role enrollments (#417 Slice G2; the global role no
        // longer distinguishes students). Only the two columns are read
        // (#1160): the unscoped fetch grows with every past term. The rule
        // is `CourseRoster.isStudent`, so a NULL or unknown role is a student
        // here too (#2720).
        let studentEnrollments = try await APICourseEnrollment.query(on: req.db)
            .field(\.$userID)
            .field(\.$roleRaw)
            .all()
        let studentUserIDs = Set(studentEnrollments.filter(CourseRoster.isStudent).map(\.userID))
        return try await loadGradesCSVStudentRows(ids: Array(studentUserIDs), on: req.db)
    }

    /// The roster rows for `ids`, sorted by username in the database. The
    /// export writes three columns per student, so it reads only those three
    /// and decodes each by name: hydrating a full `APIUser` per student took
    /// most of the export's server CPU (docs/database-performance.md, "What it found").
    private func loadGradesCSVStudentRows(
        ids: [UUID], on db: any Database
    ) async throws -> [GradesCSVStudent] {
        guard !ids.isEmpty else { return [] }
        guard let sql = db as? (any SQLDatabase) else {
            return try await APIUser.query(on: db)
                .filter(\.$id ~~ ids)
                .sort(\.$username, .ascending)
                .all()
                .compactMap { user in
                    user.id.map { GradesCSVStudent(id: $0, username: user.username, studentID: user.studentID) }
                }
        }
        let rows = try await sql.select()
            .column("id")
            .column("username")
            .column("student_id")
            .from(APIUser.schema)
            .where("id", .in, SQLBind.group(ids))
            .orderBy("username", .ascending)
            .all()
        return try rows.map { row in
            GradesCSVStudent(
                id: try row.decode(column: "id", as: UUID.self),
                username: try row.decode(column: "username", as: String.self),
                studentID: try row.decode(column: "student_id", as: String?.self))
        }
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

    /// Returns the best earned points per (user, setup): the highest grade
    /// percentage across ALL results for ALL submissions (browser and worker
    /// alike), converted to points via the manifest total.
    ///
    /// Using percentage × manifest-total rather than raw earnedPoints means the
    /// CSV column is on a stable scale: the instructor knows exactly what LEARN
    /// max to enter (the manifest total), and a 100 % browser result is never
    /// overwritten by a lower-percentage worker result from a later regrading.
    private func bestGradePointsByUserAndSetup(
        bestPercentByKey: [StudentSetupKey: Int],
        setupByID: [String: APITestSetup]
    ) -> [String: Double] {
        // One total per setup, not one per (user, setup) key.
        let totalBySetupID = setupByID.compactMapValues { suiteTotalPoints(props: $0.decodedManifest()) }
        var best: [String: Double] = [:]
        for (key, pct) in bestPercentByKey {
            guard let total = totalBySetupID[key.setupID] else { continue }
            best["\(key.userID.uuidString.lowercased())::\(key.setupID)"] = Double(pct) / 100.0 * total
        }
        return best
    }

    private func renderGradesCSV(
        students: [GradesCSVStudent],
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
            let userID = student.id
            var row: [String] = [student.studentID ?? "", "#\(student.username)"]
            for assignment in sortedAssignments {
                let key = "\(userID.uuidString.lowercased())::\(assignment.testSetupID)"
                if let points = bestPointsByUserAndSetup[key] {
                    row.append(String(cFormat: "%.1f", points))
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
