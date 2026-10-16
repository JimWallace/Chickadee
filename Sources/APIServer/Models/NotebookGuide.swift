// APIServer/Models/NotebookGuide.swift
//
// The student guide: what the notebook editor shows beside each task (notebook
// views brief, NB3/NB4). Served by `GET /testsetups/:id/notebook-guide.json`
// and built by `NotebookGuideBuilder`.
//
// It carries public results only. A secret or release test is a count in
// `hiddenCount` and nothing more, and a check's `detail` and `hint` are what
// the results page already shows for it. It is a read of results that already
// exist: nothing here runs a test.

import Core

struct NotebookGuide: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// The declared language's raw value, or nil for none.
    var language: String?
    /// The latest attempt, or nil when the student has not submitted.
    var attempt: Attempt?
    var tasks: [Task]
    /// Each anchor's source in this student's personalized starter, keyed by
    /// the anchor's name, or `section:<heading>` for a section anchor. The
    /// editor compares a cell with it to show "Still the starter code".
    /// Trailing whitespace and line endings are already normalized.
    var starterSources: [String: String]
    var reflections: [Reflection]

    struct Attempt: Codable, Sendable, Equatable {
        var number: Int
        /// True while the attempt is still being graded. The other fields are
        /// then nil.
        var pending: Bool
        var percent: Int?
        var points: Double?
        var pointsPossible: Int?
        var url: String
    }

    struct Task: Codable, Sendable, Equatable {
        /// The suite section, or nil for the checks in no section.
        var sectionID: String?
        /// The section name as written, which is its `## ` heading.
        var heading: String?
        /// "Task 2" from "Task 2: Average heart rate", or nil when the heading
        /// has no label before a colon.
        var label: String?
        /// "Average heart rate", or the whole heading.
        var name: String
        /// Every test in the task, hidden ones included.
        var points: Int
        /// The anchors of the task's public tests, or its heading when it has
        /// none. A hidden test's anchor is never sent.
        var anchors: [Anchor]
        /// `fresh` before the first attempt. After it, `pass` or `fail` from
        /// the task's public checks, or nil when the task has no public check,
        /// a public check has no outcome, or the attempt is still being
        /// graded. The editor turns it into `starter` when the cell still
        /// matches the starter.
        var status: String?
        var checks: [Check]
        /// The tests in the task that are not public.
        var hiddenCount: Int
    }

    struct Anchor: Codable, Sendable, Equatable {
        /// `function` or `variable` for a name the solution defines, `name`
        /// for a name it does not, or `section`.
        var kind: String
        var name: String
        /// True when a script test names several defined names, and this one
        /// was taken because it comes first in the notebook.
        var ambiguous: Bool?
    }

    struct Check: Codable, Sendable, Equatable {
        var name: String
        /// `check` (a notebook check), `family` (a pattern-family case) or
        /// `script` (a hand-written test).
        var kind: String
        /// The latest attempt's status for this check, or nil before one.
        var result: String?
        /// The failure text the results page shows, after the check's
        /// failure-detail setting. Only on a failure.
        var detail: String?
        /// The instructor's hint. Only on a failure.
        var hint: String?
    }

    struct Reflection: Codable, Sendable, Equatable {
        var label: String
        var tag: String
        var readBy: String
    }
}
