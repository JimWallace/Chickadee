// Tests/APITests/ElementaryPageFixtures+InstructorIntegrations.swift
//
// The instructor integration pages (LEARN, LMS grades, GitHub and slip days),
// for ElementaryPageGuardTests.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var instructorIntegrationPages: [ElementaryPageFixture] {
        [instructorBrightspacePage, instructorLTIGradesPage, instructorGitHubPage, instructorSlipDaysPage]
    }

    private static func rosterAvatar(_ seed: UInt64) -> AvatarPresentation {
        AvatarPresentation(
            for: AvatarSpec.drawn(fromSeed: seed), size: .roster, accessibility: .decorative, isStaff: false)
    }

    static var instructorBrightspacePage: ElementaryPageFixture {
        var mapped = BrightspaceAssignmentRow(
            assignmentID: "A1B2C3", title: "Lab 1", gradeFieldValue: "123", lastSyncText: "Sep 3",
            lastSyncStatus: "error", lastSyncDetail: "HTTP 500", syncedCount: 20, pendingCount: 1, erroredCount: 2,
            hasSyncActivity: true, hasPending: true, hasErrored: true)
        mapped.isMapped = true
        mapped.syncDetailText = "HTTP 500"
        mapped.hasSyncError = true
        var unmapped = BrightspaceAssignmentRow(
            assignmentID: "D4E5F6", title: "Lab 2", gradeFieldValue: "", lastSyncText: "—", lastSyncStatus: "none",
            lastSyncDetail: nil, syncedCount: 0, pendingCount: 0, erroredCount: 0, hasSyncActivity: false,
            hasPending: false, hasErrored: false)
        unmapped.syncDetailText = "Not synced yet"
        let student = BrightspaceReadinessRow(
            username: "ada", displayName: "Ada Lovelace", detail: "Not on the LEARN classlist.", userID: "u-1",
            unenrollURL: "/courses/c1/unenroll/u-1", avatar: rosterAvatar(9), hasAvatar: true)

        func render(
            enabled: Bool, hasCourse: Bool, archived: Bool = false, linked: Bool = true, connected: Bool = true,
            serviceAccount: Bool = false, healthy: Bool = true, rows: [BrightspaceAssignmentRow] = [],
            unreachable: [BrightspaceReadinessRow] = [], lti: Bool = false
        ) -> String {
            var model = InstructorBrightspaceContext(
                hasActiveCourse: hasCourse, courseIsArchived: archived, brightspaceSyncEnabled: enabled,
                courseLinked: linked, orgUnitDisplay: linked ? "CS135 Fall 2026 (1106038)" : nil,
                orgUnitFieldValue: linked ? "1106038" : "",
                account: .init(
                    connected: connected, identity: connected ? "Ada Lovelace" : nil,
                    since: connected ? " (since Sep 1, 9:00 AM)" : nil),
                syncIdentity: .init(
                    name: connected ? "Ada Lovelace" : nil, hasName: connected, isMe: connected,
                    connected: healthy, needsReconnect: !healthy),
                showConnectForm: enabled && !connected && !archived,
                showIdentityActions: connected && !archived, showUseMyIdentity: false,
                flashSuccess: connected ? "LEARN account connected." : nil, flashError: nil,
                canSyncNow: enabled && !archived && !lti, doNotSyncToken: BrightspaceSync.doNotSyncToken,
                assignmentRows: rows, hasAssignments: !rows.isEmpty, canReconcile: linked && !archived,
                unreachableStudents: unreachable, hasUnreachable: !unreachable.isEmpty)
            model.showLTIGradesLink = lti
            model.usesLTIGrades = lti
            model.usesServiceAccount = serviceAccount
            model.syncHealthy = healthy
            model.pushesAsText = serviceAccount ? "Service account" : "Ada Lovelace"
            model.pushesAsNote = serviceAccount ? "" : "Designated instructor"
            model.lastSyncISO = rows.isEmpty ? nil : "2026-09-03T14:10:00Z"
            model.lastSyncText = rows.isEmpty ? "Never" : "Sep 3, 2:10 PM"
            model.canBindOrgUnit = !archived
            model.readinessSummary = "1 student can’t receive grades · checked Sep 3, 2:10 PM"
            return InstructorBrightspacePage(page: page(currentUser: signedInAdmin), model: model).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorBrightspacePage",
            archetype: .instructorTabbed,
            renders: [
                render(enabled: false, hasCourse: false),
                render(enabled: true, hasCourse: false, connected: false),
                render(enabled: false, hasCourse: true, lti: true),
                render(
                    enabled: true, hasCourse: true, rows: [mapped, unmapped], unreachable: [student], lti: true),
                render(
                    enabled: true, hasCourse: true, archived: true, linked: false, connected: false,
                    serviceAccount: true, healthy: false),
                render(enabled: true, hasCourse: true, healthy: false, rows: [unmapped]),
            ]
        )
    }

    static var instructorLTIGradesPage: ElementaryPageFixture {
        func render(
            hasCourse: Bool = true, linked: Bool = true, service: Bool = true, ags: Bool = true,
            choose: Bool = true, failures: [LTIGradeFailureRow] = []
        ) -> String {
            InstructorLTIGradesPage(
                page: page(currentUser: signedInAdmin),
                flash: FlashMessages(success: ags ? "Every grade is queued." : nil),
                hasActiveCourse: hasCourse, courseCode: "CS135", platformName: linked ? "D2L Brightspace" : nil,
                isLinked: linked, hasGradeService: service, usesAGS: ags, canChooseTransport: choose,
                canPushAll: hasCourse && ags, canLinkStudents: ags && choose, sentCount: 28, waitingCount: 2,
                failedCount: failures.count, failures: failures, failuresTruncated: failures.count > 1
            ).render()
        }
        let failures = [
            LTIGradeFailureRow(student: "ada", assignment: "Lab 1", reason: "HTTP 400"),
            LTIGradeFailureRow(student: "bo", assignment: "Lab 2", reason: "The LMS did not answer."),
        ]
        return ElementaryPageFixture(
            typeName: "InstructorLTIGradesPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false, linked: false, ags: false),
                render(linked: false, ags: false),
                render(service: false, ags: false, choose: false),
                render(ags: false),
                render(choose: false),
                render(failures: failures),
            ]
        )
    }

    static var instructorGitHubPage: ElementaryPageFixture {
        let binding = APIGitHubCourseOrganization()
        binding.orgLogin = "uwaterloo-cs"
        binding.installationID = 77
        let grants = GitHubAppGrants(permissions: ["administration": "write", "members": "read"], events: [])
        let rows = [
            InstructorGitHubAssignmentRow(
                testSetupID: "ts1", title: "Lab 1",
                templateOptions: [
                    SelectOption(value: "", label: "None", selected: false),
                    SelectOption(value: "t1", label: "lab1-starter", selected: true),
                ], templateName: "lab1-starter", repositoryCount: 4),
            InstructorGitHubAssignmentRow(
                testSetupID: "ts2", title: "Lab 2",
                templateOptions: [SelectOption(value: "", label: "None", selected: true)],
                templateName: nil, repositoryCount: 0),
        ]
        let repositories = [
            InstructorGitHubRepositoryRow(
                assignmentTitle: "Lab 1", studentName: "Ada Lovelace", repositoryName: "lab1-ada",
                repositoryURL: "https://github.com/uwaterloo-cs/lab1-ada", lastPushedText: "Sep 3, 2:10 PM",
                lastPushedISO: "2026-09-03T14:10:00Z", archived: true),
            InstructorGitHubRepositoryRow(
                assignmentTitle: "Lab 1", studentName: "Bo", repositoryName: "lab1-bo",
                repositoryURL: "https://github.com/uwaterloo-cs/lab1-bo", lastPushedText: "Not reported",
                lastPushedISO: nil, archived: false),
        ]
        func render(
            hasCourse: Bool = true, organization: InstructorGitHubOrganization? = nil, canEdit: Bool = true,
            full: Bool = false
        ) -> String {
            InstructorGitHubPage(
                page: page(currentUser: signedInAdmin), flash: FlashMessages(error: full ? nil : "Bind refused."),
                hasActiveCourse: hasCourse, courseCode: "CS135", canEdit: canEdit, organization: organization,
                installURL: "https://github.com/apps/chickadee-fixture/installations/new",
                organizationText: "uwaterloo-cs", assignments: full ? rows : [], templatesUnavailable: !full,
                repositories: full ? repositories : []
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorGitHubPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false),
                render(),
                render(canEdit: false),
                render(organization: InstructorGitHubOrganization(binding: binding, forksAllowed: nil, grants: nil)),
                render(
                    organization: InstructorGitHubOrganization(binding: binding, forksAllowed: true, grants: grants),
                    full: true),
                render(
                    organization: InstructorGitHubOrganization(binding: binding, forksAllowed: false, grants: grants),
                    canEdit: false, full: true),
            ]
        )
    }

    static var instructorSlipDaysPage: ElementaryPageFixture {
        let spend = SlipDayLedgerSpendRow(
            id: "s1", assignmentTitle: "Lab 1", spentAtText: "Sep 1", extensionDueAtText: "Sep 3, 2:00 PM",
            isRefunded: false, refundedAtText: "", canRefund: true)
        let refunded = SlipDayLedgerSpendRow(
            id: "s2", assignmentTitle: "Lab 2", spentAtText: "Sep 4", extensionDueAtText: "Sep 6, 2:00 PM",
            isRefunded: true, refundedAtText: "Sep 5", canRefund: false)
        let students = [
            SlipDayStudentRow(
                userID: "u1", displayName: "Ada Lovelace", username: "ada", used: 1, remaining: 3, total: 4,
                adjustment: 1, hasSpends: true, spends: [spend, refunded], avatar: rosterAvatar(3),
                pips: SlipDayPip.pips(total: 4, used: 1, extra: 1), leftText: "3 of 4 left",
                adjustmentText: "+1 granted", refundableSpends: [spend], hasRefundable: true),
            SlipDayStudentRow(
                userID: "u2", displayName: "Bo", username: "bo", used: 0, remaining: 3, total: 3, adjustment: 0,
                hasSpends: false, spends: [], avatar: rosterAvatar(5),
                pips: SlipDayPip.pips(total: 3, used: 0, extra: 0), leftText: "3 of 3 left", adjustmentText: "",
                refundableSpends: [], hasRefundable: false),
        ]
        func render(
            hasCourse: Bool = true, enabled: Bool = true, canEdit: Bool = true, canManage: Bool = true,
            note: String? = nil, students: [SlipDayStudentRow] = [], filter: Bool = false
        ) -> String {
            InstructorSlipDaysPage(
                page: page(currentUser: signedInAdmin), flash: FlashMessages(success: canEdit ? "Saved." : nil),
                hasActiveCourse: hasCourse, courseCode: "CS135", enabled: enabled, daysPerStudent: 3,
                extensionHours: 24, releaseRevealHold: enabled, canEditSettings: canEdit,
                canManageLedger: canManage, settingsReadOnlyNote: note, students: students,
                perStudentText: "3 days", eachDayText: "24 hours",
                releaseHoldText: enabled ? "Held until claims lapse" : "Shown at each deadline",
                inUseText: "1 of 7 spent", inUseNote: "1 student", showFilter: filter
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorSlipDaysPage",
            archetype: .instructorTabbed,
            renders: [
                render(hasCourse: false),
                render(enabled: false),
                render(students: students, filter: true),
                render(
                    canEdit: false, note: "Only this course's instructors can change slip-day policy.",
                    students: students),
                render(
                    canEdit: false, canManage: false, note: "This course is archived and is read-only.",
                    students: students),
            ]
        )
    }
}
