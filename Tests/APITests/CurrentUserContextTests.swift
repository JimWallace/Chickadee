import Core
import Fluent
import Testing

@testable import APIServer

@Suite struct CurrentUserContextTests {

    // MARK: - Instructor course derivation

    private func course(_ code: String, role: CourseRole, isActive: Bool = false) -> CourseContext {
        CourseContext(id: code, code: code, name: code, isActive: isActive, role: role)
    }

    private func user(role: String) -> APIUser {
        APIUser(username: "u", passwordHash: "", role: role)
    }

    @Test func studentOnly_hasNoInstructorSurface() {
        let ctx = CurrentUserContext(
            user: user(role: "student"),
            activeCourse: course("CS100", role: .student, isActive: true),
            enrolledCourses: [course("CS100", role: .student), course("CS200", role: .student)]
        )
        #expect(ctx.staffCourses.isEmpty)
        #expect(ctx.isStaffAnywhere == false)
        #expect(ctx.showStaffTabs == false)
        #expect(ctx.primaryStaffCourse == nil)
    }

    @Test func instructorInOneCourse_exposesSinglePrimaryLink() {
        // Instructor in CS200, student in CS100 — the Instructor surface must
        // appear even though the *active* course is one they only take.
        let ctx = CurrentUserContext(
            user: user(role: "instructor"),
            activeCourse: course("CS100", role: .student, isActive: true),
            enrolledCourses: [course("CS100", role: .student), course("CS200", role: .instructor)]
        )
        #expect(ctx.isStaffAnywhere)
        #expect(ctx.staffCourses.map(\.code) == ["CS200"])
        #expect(ctx.showStaffTabs == false)
        #expect(ctx.primaryStaffCourse?.code == "CS200")
        // The active-course Instructor link stays keyed on the active course,
        // which here is a student course — so it must be false.
        #expect(ctx.isStaffInActiveCourse == false)
    }

    @Test func instructorInManyCourses_showsStripNotSingleLink() {
        let ctx = CurrentUserContext(
            user: user(role: "instructor"),
            activeCourse: course("CS200", role: .instructor, isActive: true),
            enrolledCourses: [course("CS200", role: .instructor), course("CS300", role: .instructor)]
        )
        #expect(ctx.showStaffTabs)
        #expect(ctx.primaryStaffCourse == nil)
        #expect(ctx.staffCourses.map(\.code) == ["CS200", "CS300"])
    }

    @Test func admin_instructsEveryEnrolledCourse() {
        // An admin administers the whole deployment, so every enrolled course
        // counts as instructable regardless of the per-course role.
        let ctx = CurrentUserContext(
            user: user(role: "admin"),
            activeCourse: course("CS100", role: .student, isActive: true),
            enrolledCourses: [course("CS100", role: .student), course("CS200", role: .instructor)]
        )
        #expect(ctx.staffCourses.map(\.code) == ["CS100", "CS200"])
        #expect(ctx.showStaffTabs)
    }

    @Test func noCourseInfo_hasNoInstructorSurface() {
        // The course-free context (used by pages without tabs) must not claim
        // any instructor courses.
        let ctx = CurrentUserContext(user: user(role: "instructor"))
        #expect(ctx.staffCourses.isEmpty)
        #expect(ctx.isStaffAnywhere == false)
        #expect(ctx.primaryStaffCourse == nil)
    }

    @Test func trimsProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "  jsmith@example.edu  ",
            preferredName: "  Jane  ",
            displayName: "  Jane Smith  "
        )

        let ctx = CurrentUserContext(user: user)
        #expect(ctx.username == "jsmith")
        #expect(ctx.preferredName == "Jane")
        #expect(ctx.displayName == "Jane Smith")
        #expect(ctx.email == "jsmith@example.edu")
    }

    @Test func dropsBlankProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "   ",
            preferredName: " ",
            displayName: "\n"
        )

        let ctx = CurrentUserContext(user: user)
        #expect(ctx.preferredName == nil)
        #expect(ctx.displayName == nil)
        #expect(ctx.email == nil)
    }
}
