// Tests/APITests/ElementaryPageFixtures+Editors.swift
//
// Fixtures for the assignment editors: the edit page (standalone and as the
// workbench renders its body) and the Create Assignment page before and after
// a draft exists. The renders cover the support-file dataset states, the
// activity and student-option branches, and the section shells.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var editorPages: [ElementaryPageFixture] {
        [assignmentEditPage, assignmentNewPage]
    }

    static var assignmentEditPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "AssignmentEditPage",
            archetype: .bodyPartialShim,
            renders: [
                AssignmentEditPage(page: page(), edit: EditorSamples.edit(rich: false, embedded: nil)).render(),
                AssignmentEditPage(
                    page: page(currentUser: signedInAdmin), edit: EditorSamples.edit(rich: true, embedded: nil)
                ).render(),
                AssignmentEditPage(page: page(), edit: EditorSamples.edit(rich: true, embedded: true)).render(),
            ]
        )
    }

    static var assignmentNewPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "AssignmentNewPage",
            archetype: .titlebarPage,
            renders: [
                EditorSamples.newPage(page(), draft: false).render(),
                EditorSamples.newPage(page(currentUser: signedInAdmin), draft: true).render(),
            ]
        )
    }
}

enum EditorSamples {
    static let languageOptions = AssignmentLanguageOption.options(recorded: "python")

    static func supportFile(dataset: Bool, editable: Bool) -> EditableSuiteRow {
        EditableSuiteRow(
            name: "vitals.csv", url: "/files/vitals.csv", isTest: false, tier: "support", order: 0, dependsOn: [],
            points: 0, displayName: nil, isDataset: dataset, datasetSampleSize: dataset ? 40 : nil,
            datasetStratumColumn: dataset ? "sex" : nil,
            datasetTransforms: editable
                ? [DatasetTransform(kind: .missingValues, columns: ["bmi"], rate: 0.1)]
                : [
                    DatasetTransform(kind: .missingValues, columns: ["bmi"], rate: 0.1),
                    DatasetTransform(kind: .missingValues, columns: ["age"], rate: 0.2),
                ])
    }

    static let sections = [
        SuiteSectionShellRow(
            sectionID: "s1", name: "Question 1", isUngrouped: false,
            variables: [SuiteSectionVariableShellRow(name: "xs", valueJSON: "[1, 2]")], hasVariables: true),
        SuiteSectionShellRow(sectionID: "ungrouped", name: "", isUngrouped: true, variables: [], hasVariables: false),
    ]

    static func activity(isSet: Bool) -> ActivityEditFacts {
        ActivityEditFacts(
            kindOptions: ActivityKindOption.options(current: nil), locked: isSet, isSet: isSet, kindLabel: "Hill",
            summary: "One student holds the hill.", leaderboardVisible: true,
            leaderboardURL: "/testsetups/t1/leaderboard", needsOpponentFile: isSet, opponentFileChosen: false,
            opponentFileOptions: OpponentFileOption.options(supportFiles: ["bot.py"], current: nil),
            windowOpensAtLocal: "", windowClosesAtLocal: "")
    }

    static func edit(rich: Bool, embedded: Bool?) -> EditAssignmentContext {
        EditAssignmentContext(
            currentUser: nil, assignmentID: "abc123", testSetupID: "t1", assignmentName: "Lab 2",
            dueAt: "2026-10-01T23:59", startsAt: "", currentAssignmentFile: "assignment.ipynb",
            currentAssignmentURL: "/files/assignment.ipynb", assignmentNotebookEditURL: "/testsetups/t1/notebook",
            currentSolutionFile: rich ? "solution.ipynb" : nil,
            currentSolutionURL: rich ? "/files/solution.ipynb" : nil,
            solutionNotebookEditURL: rich ? "/testsetups/t1/notebook?file=solution" : nil, existingSuiteRows: [],
            supportFileRows: rich
                ? [supportFile(dataset: true, editable: true), supportFile(dataset: false, editable: false)] : [],
            familyRows: [], patternFamiliesJSON: "[]", notebookChecksJSON: "[]", checkSchemaJSON: "{}",
            assignmentLanguageJSON: "{}", suiteStateJSON: #"{"items":[]}"#,
            suiteSectionRows: rich ? sections : [sections[1]], sectionActionBase: "/instructor/abc123/suite-sections",
            sectionActionQuery: "", sectionFormsInPlace: true,
            globalVariableRows: rich ? [SuiteSectionVariableShellRow(name: "seed2", valueJSON: "= seed % 26")] : [],
            achievementSignalOptions: AchievementSignalPresentation.all,
            recordDimensionOptions: RecordDimensionPresentation.all, brightspaceSyncEnabled: rich,
            brightspaceGradeObjectID: nil, submissionMode: "notebook",
            githubSubmission: rich
                ? GitHubSubmissionSetting(enabled: true, statusChecks: false, starterRepository: "org/lab1-<starter>")
                : nil,
            assignmentLanguageOptions: languageOptions, activity: activity(isSet: rich), secretRevealEnabled: rich,
            solutionVisibilityAfterDue: false, passingThresholdPercent: rich ? 60 : nil,
            aiFeedback: rich ? AIFeedbackSetting(enabled: false) : nil, timeLimitSeconds: 10,
            notice: rich ? "Saved." : nil, error: rich ? "The notebook could not be read." : nil, embedded: embedded)
    }

    static func newPage(_ page: PageRequestContext, draft: Bool) -> AssignmentNewPage {
        AssignmentNewPage(
            page: page, flash: FlashMessages(notice: draft ? "Notebook uploaded." : nil),
            error: draft ? nil : "Enter a name.", assignmentName: draft ? "Lab 1" : "", startsAt: "", dueAt: "",
            sections: draft
                ? [
                    CourseSectionRow(
                        sectionID: "c1", name: "Labs", defaultGradingMode: "browser", sortOrder: 0, items: [])
                ]
                : [],
            preselectedSectionID: draft ? "c1" : "", draftID: draft ? "draft1" : nil,
            draftIDJSON: draft ? "\"draft1\"" : "null", assignmentLanguageOptions: languageOptions,
            assignmentNotebook: draft ? NewAssignmentNotebookContext(name: "a.ipynb", editURL: "/e/a") : nil,
            solutionNotebook: nil, supportFileRows: draft ? [supportFile(dataset: true, editable: true)] : [],
            detectedLanguages: draft ? ["python"] : [], detectedCapabilities: draft ? ["numpy"] : [],
            requiredLanguagesCSV: draft ? "python" : "", requiredCapabilitiesCSV: "",
            suiteSectionRows: draft ? sections : [sections[1]], suiteStateJSON: #"{"items":[]}"#,
            patternFamiliesJSON: "[]", notebookChecksJSON: "[]", checkSchemaJSON: "{}", assignmentLanguageJSON: "{}")
    }
}
