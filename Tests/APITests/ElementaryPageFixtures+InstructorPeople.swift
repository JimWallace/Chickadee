// Tests/APITests/ElementaryPageFixtures+InstructorPeople.swift
//
// The instructor Students and New term tabs and the admin course page (the
// "InstructorPeople" group of the Leaf-to-Elementary migration), rendered for
// ElementaryPageGuardTests.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var instructorPeoplePages: [ElementaryPageFixture] {
        [instructorStudentsPage, adminCoursePage, instructorNewTermPage]
    }

    // MARK: - Shared values

    static func rosterRow(
        id: String, role: String = "student", pending: Bool = false, learnFlag: Bool = false
    ) -> EnrolledStudentRow {
        var row = EnrolledStudentRow(
            id: id, username: "user_\(id)", displayName: "Person \(id)", role: pending ? "(pending)" : role,
            lastSeenAtText: pending ? "—" : "Oct 1, 10:00", lastSeenAtISO: pending ? nil : "2026-10-01T10:00:00Z",
            submissionsURL: pending ? "#" : "/CS135-F26/students/tok-\(id)",
            unenrollURL: "/courses/c1/unenroll/\(id)", isPending: pending,
            registerURL: pending ? "/courses/c1/pre-enroll/\(id)/register" : "")
        if pending {
            row.pendingNote = "Awaiting first login · added from CSV Sep 3"
        } else {
            row.newHandleURL = "/courses/c1/new-handle/\(id)"
            row.roleSelect = RoleSelectCell(
                userID: id, action: "/courses/c1/role/\(id)", personName: row.displayName, role: row.role)
            row.avatar = AvatarPresentation(
                for: AvatarSpec.drawn(fromSeed: UInt64(id.count)), size: .roster, accessibility: .decorative,
                isStaff: role != "student")
        }
        if learnFlag {
            row.learnFlag = "Not on LEARN"
            row.learnFlagReason = "LEARN does not list this student"
            row.learnFlagAdvice = "Remove them if they dropped"
        }
        return row
    }

    // MARK: - Pages

    static var instructorStudentsPage: ElementaryPageFixture {
        let students =
            (1...12).map { rosterRow(id: "s\($0)", learnFlag: $0 == 2) } + [rosterRow(id: "p1", pending: true)]
        let staff = [rosterRow(id: "t1", role: "ta"), rosterRow(id: "i1", role: "instructor")]
        func render(
            students: [EnrolledStudentRow], staff: [EnrolledStudentRow], readOnly: Bool, staffError: String? = nil,
            flash: FlashMessages = FlashMessages()
        ) -> String {
            InstructorStudentsPage(
                page: page(currentUser: signedInAdmin), flash: flash, activeCourseID: "c1", students: students,
                staffRows: staff, activeStudentCount: students.filter { !$0.isPending }.count,
                pendingCount: students.filter(\.isPending).count,
                showStudentFilter: ListFilterPolicy.showsFilter(rowCount: students.count),
                courseEnrollmentMode: "open", rosterReadOnly: readOnly,
                staffForm: StaffFieldsContext(
                    idPrefix: "add-staff", placeholderAllowed: true, defaultRole: .ta, errorQuery: staffError)
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorStudentsPage",
            archetype: .instructorTabbed,
            renders: [
                render(students: [], staff: [], readOnly: false),
                render(
                    students: students, staff: staff, readOnly: false, staffError: StaffFormError.unknown.rawValue,
                    flash: FlashMessages(success: "Staff member added.")),
                render(students: students, staff: staff, readOnly: true),
            ]
        )
    }

    static var adminCoursePage: ElementaryPageFixture {
        let fall = AcademicTerm(year: 2026, season: .fall)
        func course(archived: Bool, orgUnitName: String?, ai: Bool) -> AdminCourseRow {
            var row = AdminCourseRow(
                id: "c1", code: "CS135", name: "Design", isArchived: archived, enrollmentMode: "auto",
                enrollmentCount: 2, assignmentCount: 3, submissionCount: 40, createdAt: "2026-09-01T00:00:00Z",
                brightspaceOrgUnitID: "123456", brightspaceOrgUnitName: orgUnitName, brightspaceSyncEnabled: true
            ).withTerm(fall)
            row.aiFeedbackEnabled = ai
            return row
        }
        var ta = AdminCourseEnrolledUserRow(id: "u1", username: "ada", displayName: "Ada", role: "ta")
        ta.avatar = AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: 3), size: .roster, accessibility: .decorative, isStaff: true)
        ta.roleSelect = RoleSelectCell(userID: "u1", action: "/admin/courses/c1/role/u1", personName: "ada", role: "ta")
        var student = AdminCourseEnrolledUserRow(id: "u2", username: "bob", displayName: nil, role: "student")
        student.roleSelect = RoleSelectCell(
            userID: "u2", action: "/admin/courses/c1/role/u2", personName: "bob", role: "student")
        let assignments = [
            AdminCourseAssignmentRow(id: "a1", title: "Lab 1", dueAt: "Oct 1", isOpen: true, visibility: "open"),
            AdminCourseAssignmentRow(id: "a2", title: "Lab 2", dueAt: nil, isOpen: false, visibility: "preview"),
            AdminCourseAssignmentRow(id: "a3", title: "Lab 3", dueAt: nil, isOpen: false, visibility: "closed"),
        ]
        func render(_ row: AdminCourseRow, error: String?) -> String {
            AdminCoursePage(
                page: page(currentUser: signedInAdmin), flash: FlashMessages(success: "Staff member added."),
                course: row, enrolledUsers: [ta, student], assignments: assignments, isNew: false,
                courseForm: CourseFieldsContext(
                    idPrefix: "course-settings", code: row.code, name: row.name, term: fall,
                    error: CourseFormError.message(forQuery: error)),
                cloneForm: CourseFieldsContext(
                    idPrefix: "clone", code: row.code, name: row.name, term: fall?.next,
                    error: CourseCloneFormError.message(forQuery: error)),
                placeholderAllowed: true,
                staffForm: StaffFieldsContext(
                    idPrefix: "add-staff", placeholderAllowed: true, defaultRole: .instructor,
                    errorQuery: error == nil ? nil : StaffFormError.email.rawValue)
            ).render()
        }
        let empty = AdminCourseRow(
            id: "", code: "", name: "", isArchived: false, enrollmentMode: "open", enrollmentCount: 0,
            assignmentCount: 0, submissionCount: 0, createdAt: "", brightspaceSyncEnabled: false)
        let newCourse = AdminCoursePage(
            page: page(currentUser: signedInAdmin), course: empty, enrolledUsers: [], assignments: [], isNew: true,
            courseForm: CourseFieldsContext(
                idPrefix: "new-course", code: "", name: "", term: nil,
                error: CourseFormError.term.message, autofocus: true),
            placeholderAllowed: false
        ).render()
        return ElementaryPageFixture(
            typeName: "AdminCoursePage",
            archetype: .titlebarPage,
            renders: [
                newCourse,
                render(course(archived: false, orgUnitName: "Design (Fall 2026)", ai: true), error: nil),
                render(course(archived: true, orgUnitName: nil, ai: false), error: CourseCloneFormError.term.rawValue),
            ]
        )
    }

    static var instructorNewTermPage: ElementaryPageFixture {
        let form = CourseFieldsContext(
            idPrefix: "new-term", code: "CS135", name: "Design",
            term: AcademicTerm(year: 2027, season: .winter))
        func render(hasCourse: Bool, cloned: Bool, canClone: Bool, flash: FlashMessages = FlashMessages()) -> String {
            InstructorNewTermPage(
                page: page(currentUser: signedInAdmin), flash: flash, hasActiveCourse: hasCourse,
                courseCode: "CS135", courseName: "Design", termLabel: "Fall 2026", canClone: canClone,
                justCloned: cloned, cloneForm: form
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorNewTermPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false, cloned: false, canClone: false),
                render(
                    hasCourse: true, cloned: false, canClone: true, flash: FlashMessages(error: "No active course.")),
                render(hasCourse: true, cloned: false, canClone: false),
                render(hasCourse: true, cloned: true, canClone: true, flash: FlashMessages(success: "Cloned.")),
            ]
        )
    }
}
