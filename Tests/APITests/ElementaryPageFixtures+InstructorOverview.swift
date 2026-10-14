// Tests/APITests/ElementaryPageFixtures+InstructorOverview.swift
//
// The instructor Overview, Activity and AI agents tabs.

import Core
import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var instructorOverviewPages: [ElementaryPageFixture] {
        [assignmentsPage, instructorActivityPage, instructorMCPPage]
    }

    // MARK: - Shared values

    static func overviewAssignmentRow(
        setupID: String, assignmentID: String?, title: String?, status: String, validationStatus: String,
        validationSubmissionID: String? = nil, dueAt: String? = nil, variantState: String = "none",
        variantSummaryText: String = "", failedVariantSubmissionID: String? = nil, vanityURL: String? = nil,
        leaderboardURL: String? = nil
    ) -> AssignmentRow {
        AssignmentRow(
            setupID: setupID, assignmentID: assignmentID, title: title, isOpen: assignmentID.map { _ in true },
            dueAt: dueAt, status: status, sortOrder: nil, validationStatus: validationStatus,
            validationSubmissionID: validationSubmissionID, variantState: variantState,
            variantSummaryText: variantSummaryText, failedVariantSubmissionID: failedVariantSubmissionID,
            suiteCount: 4, createdAt: "Sep 3, 2026 9:00 AM",
            submittedStudentCount: assignmentID == nil ? nil : 3, vanityURL: vanityURL, leaderboardURL: leaderboardURL)
    }

    /// One row of every kind: each status, each validation state, each
    /// variant state, an unpublished setup, and material of every shape.
    static var overviewItems: [InstructorSectionItem] {
        let rows = [
            overviewAssignmentRow(
                setupID: "ts1", assignmentID: "abc123", title: "Lab 1 & <Warmup>", status: "open",
                validationStatus: "passed", dueAt: "Oct 1, 2026 5:00 PM", vanityURL: "/CS135-F26/lab-1",
                leaderboardURL: "/testsetups/ts1/leaderboard"),
            overviewAssignmentRow(
                setupID: "ts2", assignmentID: "def456", title: "Lab 2", status: "preview", validationStatus: "failed",
                validationSubmissionID: "sub-v", variantState: "failed", variantSummaryText: "1 of 4 variants failed",
                failedVariantSubmissionID: "sub-fv"),
            overviewAssignmentRow(
                setupID: "ts3", assignmentID: "ghi789", title: "Lab 3", status: "closed", validationStatus: "pending",
                validationSubmissionID: "sub-p", variantState: "pending", variantSummaryText: "4 variants running"),
            overviewAssignmentRow(
                setupID: "ts4", assignmentID: "jkl012", title: "Lab 4", status: "closed",
                validationStatus: "no-runner", variantState: "passed", variantSummaryText: "4 variants passed"),
            overviewAssignmentRow(
                setupID: "ts5", assignmentID: "mno345", title: "Lab 5", status: "open", validationStatus: "failed"),
            overviewAssignmentRow(
                setupID: "ts6", assignmentID: "pqr678", title: "Lab 6", status: "closed", validationStatus: "other"),
            overviewAssignmentRow(
                setupID: "ts7", assignmentID: nil, title: nil, status: "unpublished",
                validationStatus: "unpublished"),
        ]
        let courseID = UUID()
        let materials = [
            APICourseContentItem(
                id: UUID(), courseID: courseID, sortOrder: 1, title: "Slides <1>", kind: .slides,
                itemDescription: "Week & one",
                links: [
                    ContentLink(label: "PDF", url: "https://example.com/a.pdf?x=1&y=2"),
                    ContentLink(label: "Jupyter Notebook", url: "/nb"),
                ],
                attachments: [
                    ContentAttachment(id: UUID(), originalName: "deck.pdf", sizeBytes: 2048, sortOrder: 0),
                    ContentAttachment(id: UUID(), originalName: "data.zip", sizeBytes: 10, sortOrder: 1, label: "Data"),
                ],
                updatedLabel: "2026-05-11"),
            APICourseContentItem(
                id: UUID(), courseID: courseID, sortOrder: 2, title: "Notes", kind: .notebook, isPublished: false),
            APICourseContentItem(
                id: UUID(), courseID: courseID, sortOrder: 3, title: "Week 2", kind: .heading,
                itemDescription: "Trees"),
            APICourseContentItem(id: UUID(), courseID: courseID, sortOrder: 4, title: "Week 3", kind: .heading),
            APICourseContentItem(
                id: UUID(), courseID: courseID, sortOrder: 5, title: "Outline", kind: .outline, itemDescription: ""),
        ]
        return rows.map(InstructorSectionItem.assignment)
            + materials.map { InstructorSectionItem.material(ContentItemRow(from: $0)) }
    }

    static var overviewSections: [CourseSectionRow] {
        [
            CourseSectionRow(
                sectionID: "s1", name: "Labs & <Quizzes>", defaultGradingMode: "worker", sortOrder: 0,
                items: Array(overviewItems.prefix(4))),
            CourseSectionRow(sectionID: "s2", name: "Readings", defaultGradingMode: "browser", sortOrder: 1, items: []),
        ]
    }

    static var activityDays: [ActivityDay] {
        func row(link: String?, detail: String) -> CourseTimelineRow {
            CourseTimelineRow(
                timestamp: "Oct 1, 2026 3:42 PM", timestampISO: "2026-10-01T19:42:00Z", actor: "ada",
                category: "Content edit", summary: "edited", target: "Lab <1>", detail: detail, link: link,
                occurredAt: Date(timeIntervalSince1970: 0), clockText: "3:42 PM", categoryKey: "edit",
                tileKind: "graded", iconHref: "#i-pencil")
        }
        return [
            ActivityDay(label: "Today", rows: [row(link: "/instructor/abc/versions?a=1&b=2", detail: "v3 & web")]),
            ActivityDay(label: "Sep 26", rows: [row(link: nil, detail: "")]),
        ]
    }

    static let activityStaffOptions = [
        ActivityStaffOption(username: "", displayName: "Everyone", selected: false),
        ActivityStaffOption(username: "ada", displayName: "Ada <L>", selected: true),
    ]

    static func agentAccess(
        feedbackOn: Bool, assignments: Bool = false, canAttest: Bool = false, attestedAtISO: String? = nil
    ) -> AgentAccessFacts {
        AgentAccessFacts(
            feedbackOn: feedbackOn,
            feedbackAssignments: assignments
                ? [AgentFeedbackAssignmentRow(title: "Lab <1>", reviewURL: "/instructor/abc/feedback", draftCount: 2)]
                : [],
            canAttest: canAttest, attestedAtISO: attestedAtISO)
    }

    // MARK: - Pages

    static var assignmentsPage: ElementaryPageFixture {
        func render(
            _ user: CurrentUserContext?, sections: [CourseSectionRow], ungrouped: [InstructorSectionItem]
        ) -> String {
            AssignmentsPage(
                page: page(currentUser: user), sections: sections, ungroupedItems: ungrouped,
                hasSections: !sections.isEmpty, showUngroupedBlock: !ungrouped.isEmpty || sections.isEmpty,
                showEmptyMessage: sections.isEmpty && ungrouped.isEmpty, enrolledStudentCount: 12
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AssignmentsPage",
            archetype: .instructorTabbed,
            renders: [
                render(nil, sections: [], ungrouped: []),
                render(signedInAdmin, sections: [], ungrouped: overviewItems),
                render(signedInAdmin, sections: overviewSections, ungrouped: Array(overviewItems.dropFirst(4))),
                render(signedInAdmin, sections: overviewSections, ungrouped: []),
            ]
        )
    }

    static var instructorActivityPage: ElementaryPageFixture {
        func render(active: Bool, days: [ActivityDay], filtered: Bool) -> String {
            InstructorActivityPage(
                page: page(currentUser: signedInAdmin), hasActiveCourse: active, days: days,
                staffOptions: active ? activityStaffOptions : [], hasRows: !days.isEmpty, filtered: filtered
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorActivityPage",
            archetype: .instructorTabbed,
            renders: [
                render(active: false, days: [], filtered: false),
                render(active: true, days: activityDays, filtered: true),
                render(active: true, days: [], filtered: false),
                render(active: true, days: [], filtered: true),
            ]
        )
    }

    static var instructorMCPPage: ElementaryPageFixture {
        func render(
            active: Bool = true, customized: Bool, canEdit: Bool, mcpDisabled: Bool = false,
            access: AgentAccessFacts, flash: FlashMessages = FlashMessages()
        ) -> String {
            InstructorMCPPage(
                page: page(currentUser: signedInAdmin), flash: flash, hasActiveCourse: active, courseCode: "CS135",
                guidanceText: "Write \"plainly\" & don't <shout>.", guidanceLength: 32, isCustomized: customized,
                showResetButton: canEdit && customized, sourceNote: customized ? "Customized" : "Chickadee default",
                maxLength: 8000, canEdit: canEdit,
                readOnlyNote: canEdit ? nil : "Only this course's instructors can edit its authoring voice.",
                mcpDisabled: mcpDisabled, agentAccess: access
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorMCPPage",
            archetype: .instructorTabbed,
            renders: [
                render(active: false, customized: false, canEdit: false, access: agentAccess(feedbackOn: false)),
                render(
                    customized: true, canEdit: true, access: agentAccess(feedbackOn: false),
                    flash: FlashMessages(success: "Saved.")),
                render(
                    customized: false, canEdit: false, mcpDisabled: true,
                    access: agentAccess(feedbackOn: true, canAttest: true),
                    flash: FlashMessages(error: "No active course.")),
                render(
                    customized: false, canEdit: true,
                    access: agentAccess(
                        feedbackOn: true, assignments: true, canAttest: true, attestedAtISO: "2026-10-01T00:00:00Z")),
                render(customized: true, canEdit: true, access: agentAccess(feedbackOn: true, assignments: true)),
            ],
            isExemplar: true
        )
    }
}
