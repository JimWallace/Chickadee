// APIServer/Models/InstructorSuiteOutline.swift
//
// The instructor's suite outline (notebook views NB6, design frame 18c): each
// suite section with its items, each item with its anchor cell and its result
// on the solution and, from NB8, on the starter. The workbench rail draws it,
// and NB7's margin cards read the same payload through `chickadee:set-suite`.
// The contract is in docs/notebook-guide.md, "The instructor's suite outline".
//
// Course staff only: it names every tier, hidden tests included.

import Foundation

struct InstructorSuiteOutline: Codable, Sendable, Equatable {
    static let currentVersion = 1

    var version: Int
    var validation: Validation
    var totals: Totals
    /// Each suite section in order, then the items in no section, when any.
    var sections: [Section]
    /// The items that link to no cell, whatever their section.
    var unlinked: [Item]

    struct Validation: Codable, Sendable, Equatable {
        /// The assignment's `validationStatus`, or nil before any run.
        var status: String?
        var solutionRunAt: Date?
        var issues: [Issue]
        /// The time of the last starter run (NB8), or nil before one.
        var starterRunAt: Date?
        /// Why the last starter run did not run ("Starter didn't run"), or
        /// nil. Such a run flags nothing.
        var starterError: String?
    }

    struct Issue: Codable, Sendable, Equatable {
        var itemID: String
        /// `failsOnSolution`, or `passesOnStarter` for a test worth points
        /// that the starter passes. In that order.
        var kind: String
    }

    struct Totals: Codable, Sendable, Equatable {
        var checks: Int
        var points: Int
    }

    struct Section: Codable, Sendable, Equatable {
        /// The suite section, or nil for the items in no section.
        var id: String?
        /// The section name as written, or nil for the items in no section.
        var title: String?
        /// "Task 2" from "Task 2: Average heart rate", or nil.
        var label: String?
        var points: Int
        /// The section's linked items. Its unlinked ones are in `unlinked`.
        var items: [Item]
    }

    struct Item: Codable, Sendable, Equatable {
        /// The script filename, which is unique in the suite.
        var id: String
        var name: String
        /// `check`, `family` or `script`.
        var kind: String
        /// The notebook check or pattern kind, for a generated item.
        var checkKind: String?
        var tier: String
        var points: Int
        var anchor: Anchor?
        var solution: RunResult?
        /// The result on the starter (NB8), or nil before a starter run.
        var starter: RunResult?
        /// The family or check id of a generated item, or nil.
        var generatorID: String?
        /// The test's script, shown when its card opens (NB7).
        var source: String?
    }

    struct Anchor: Codable, Sendable, Equatable {
        /// `function`, `variable`, `name` or `section`.
        var kind: String
        var name: String
        /// `pinned` when the author pinned the test to this cell, else `auto`.
        var source: String
        var ambiguous: Bool
    }

    struct RunResult: Codable, Sendable, Equatable {
        /// `pass`, `fail`, `error` or `timeout`.
        var result: String
        /// The short result of a failure.
        var detail: String?
    }
}
