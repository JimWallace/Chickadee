// Tests/APITests/WebRoutesBadgeTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesTestCase.swift for
// shared helpers (auth, seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class WebRoutesBadgeTests: WebRoutesTestCase {

    // MARK: - Class-wide badge award gating (v0.4.127)
    //
    // Class-wide badges (Pathfinder, Trailblazer, Speed Champion,
    // Minimalist) are class-LEVEL recognitions and only meaningful for
    // enrolled students.  Admin/instructor test submissions used to
    // earn — and lock in — these badges before any real student got
    // to attempt the assignment.  These tests pin down the fix at both
    // award sites:
    //   - Pathfinder: WebRoutes+Submission.swift, on submit
    //   - Trailblazer/Speed Champion/Minimalist: ClassAchievements.swift,
    //     on 100%-grade result post
    func testPathfinderNotAwardedToAdminSubmission() async throws {
        try await insertSetup(id: "setup_pf_admin")
        try await insertAssignment(
            testSetupID: "setup_pf_admin", title: "Pathfinder Test", isOpen: true
        )

        try await submitOnceAs(username: "admin_pf", role: "admin", setupID: "setup_pf_admin")

        let badges = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_pf_admin")
            .all()
        XCTAssertTrue(
            badges.isEmpty,
            "Admin submission must not earn Pathfinder. Found: \(badges.map { $0.achievementID })")
    }

    func testPathfinderAwardedToFirstStudentEvenAfterAdminSubmits() async throws {
        try await insertSetup(id: "setup_pf_mixed")
        try await insertAssignment(
            testSetupID: "setup_pf_mixed", title: "Pathfinder Test 2", isOpen: true
        )

        // Admin submits first — should NOT earn Pathfinder.
        try await submitOnceAs(username: "admin_pf2", role: "admin", setupID: "setup_pf_mixed")
        let afterAdmin = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_pf_mixed")
            .filter(\.$achievementID == "pathfinder")
            .first()
        XCTAssertNil(afterAdmin, "Admin submission should leave Pathfinder unawarded")

        // Real student submits next — should earn Pathfinder.
        try await submitOnceAs(username: "student_pf2", role: "student", setupID: "setup_pf_mixed")
        let afterStudent = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_pf_mixed")
            .filter(\.$achievementID == "pathfinder")
            .first()
        XCTAssertNotNil(
            afterStudent,
            "First STUDENT submission should earn Pathfinder, even when an admin submitted earlier")
        guard let badge = afterStudent else { return }
        let student = try await APIUser.query(on: app.db)
            .filter(\.$username == "student_pf2")
            .first()
        XCTAssertEqual(
            badge.userID, try student?.requireID(),
            "Pathfinder must be held by the first-student submitter, not the admin")
    }

    func testAwardClassBadgesFor100PercentSkipsAdminAndInstructor() async throws {
        try await insertSetup(id: "setup_100_gate")

        // Three users with distinct roles, all saved.
        let admin = APIUser(
            username: "admin_100", passwordHash: try Bcrypt.hash("pass"), role: "admin"
        )
        try await admin.save(on: app.db)
        let instructor = APIUser(
            username: "instructor_100", passwordHash: try Bcrypt.hash("pass"), role: "instructor"
        )
        try await instructor.save(on: app.db)
        let student = APIUser(
            username: "student_100", passwordHash: try Bcrypt.hash("pass"), role: "student"
        )
        try await student.save(on: app.db)

        // Admin call — must persist no badges.
        try await awardClassBadgesFor100Percent(
            testSetupID: "setup_100_gate",
            userID: try admin.requireID(),
            submissionID: "sub_admin_100",
            executionTimeMs: 100,
            attemptNumber: 1,
            on: app.db
        )
        let afterAdmin = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_100_gate")
            .all()
        XCTAssertTrue(
            afterAdmin.isEmpty,
            "Admin's 100% submission must not earn class-wide badges. Found: \(afterAdmin.map { $0.achievementID })")

        // Instructor call — also must persist no badges.
        try await awardClassBadgesFor100Percent(
            testSetupID: "setup_100_gate",
            userID: try instructor.requireID(),
            submissionID: "sub_instr_100",
            executionTimeMs: 50,
            attemptNumber: 1,
            on: app.db
        )
        let afterInstructor = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_100_gate")
            .all()
        XCTAssertTrue(
            afterInstructor.isEmpty,
            "Instructor's 100% submission must not earn class-wide badges. Found: \(afterInstructor.map { $0.achievementID })"
        )

        // Student call — should award all three (Trailblazer + Speed Champion + Minimalist).
        try await awardClassBadgesFor100Percent(
            testSetupID: "setup_100_gate",
            userID: try student.requireID(),
            submissionID: "sub_student_100",
            executionTimeMs: 200,
            attemptNumber: 2,
            on: app.db
        )
        let afterStudent = try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == "setup_100_gate")
            .all()
        let earned = Set(afterStudent.map(\.achievementID))
        XCTAssertEqual(
            earned, ["trailblazer", "speed_champion", "minimalist"],
            "Student's 100% submission should earn all three class-wide badges. Got: \(earned)")
        for badge in afterStudent {
            XCTAssertEqual(
                badge.userID, try student.requireID(),
                "Badge \(badge.achievementID) should belong to the student, not admin/instructor")
        }
    }
}
