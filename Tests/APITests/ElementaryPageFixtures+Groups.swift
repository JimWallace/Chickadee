// Tests/APITests/ElementaryPageFixtures+Groups.swift
//
// The instructor Groups tab, and the Students tab with its Group column
// (docs/lab-groups.md, slice 1), rendered for ElementaryPageGuardTests.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var groupPages: [ElementaryPageFixture] {
        [
            instructorGroupsPage, instructorStudentsPageWithGroups, joinSessionPage,
            leaderboardPresentPageWithSession, sessionAttendancePage,
        ]
    }

    static var instructorGroupsPage: ElementaryPageFixture {
        let groups = [
            GroupSetPanel.Row(id: "g1", name: "Lab 101", memberCount: 24),
            GroupSetPanel.Row(id: "g2", name: "Lab 102", memberCount: 1),
            GroupSetPanel.Row(id: "g3", name: "Lab 103", memberCount: 0),
        ]
        func panel(isManual: Bool = true, groups: [GroupSetPanel.Row]) -> GroupSetPanel {
            GroupSetPanel(
                id: "s1", name: "Lab sections", isManual: isManual, groups: groups, studentCount: 27,
                ungroupedCount: 2)
        }
        func render(
            hasCourse: Bool = true, canEdit: Bool = true, note: String? = nil, set: GroupSetPanel? = nil,
            flash: FlashMessages = FlashMessages()
        ) -> String {
            InstructorGroupsPage(
                page: page(currentUser: signedInAdmin), flash: flash, hasActiveCourse: hasCourse,
                courseCode: "CS135", canEdit: canEdit, readOnlyNote: note, groupSet: set
            ).render()
        }
        let taNote = "Only this course's instructors can change its groups."
        return ElementaryPageFixture(
            typeName: "InstructorGroupsPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false),
                render(),
                render(canEdit: false, note: taNote),
                render(set: panel(groups: [])),
                render(set: panel(groups: groups), flash: FlashMessages(success: "Group added.")),
                render(canEdit: false, note: taNote, set: panel(groups: groups)),
                render(set: panel(isManual: false, groups: groups)),
                render(
                    set: panel(groups: groups),
                    flash: FlashMessages(
                        success: "Placed 25 students. Added Lab 101, Lab 102.",
                        notice: "No student of this course has these usernames: jdoe.")),
            ]
        )
    }

    /// The Students tab when the course has a group set: a select per
    /// student for an instructor, the group's name for a TA.
    static var instructorStudentsPageWithGroups: ElementaryPageFixture {
        let options = [GroupOption(id: "g1", name: "Lab 101"), GroupOption(id: "g2", name: "Lab 102")]
        let students = (1...12).map { index in
            var row = rosterRow(id: "s\(index)")
            let groupID = index.isMultiple(of: 3) ? "" : options[index % 2].id
            row.groupName = options.first { $0.id == groupID }?.name
            row.groupSelect = GroupSelectCell(
                userID: row.id, setID: "set1", personName: row.displayName, groupID: groupID, options: options)
            return row
        }
        func render(readOnly: Bool) -> String {
            InstructorStudentsPage(
                page: page(currentUser: signedInAdmin), activeCourseID: "c1", students: students, staffRows: [],
                activeStudentCount: students.count, pendingCount: 0, showStudentFilter: true,
                courseEnrollmentMode: "open", rosterReadOnly: readOnly,
                staffForm: StaffFieldsContext(
                    idPrefix: "add-staff", placeholderAllowed: true, defaultRole: .ta, errorQuery: nil),
                showsGroups: true
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorStudentsPage",
            archetype: .instructorTabbed,
            renders: [render(readOnly: false), render(readOnly: true)]
        )
    }
}
