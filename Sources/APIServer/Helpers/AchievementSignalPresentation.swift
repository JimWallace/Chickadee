// APIServer/Helpers/AchievementSignalPresentation.swift
//
// Single source of truth for how the achievements editor presents each
// condition `AchievementSignal`.  The editor's condition-builder renders its
// signal dropdown from `AchievementSignalPresentation.all`, and
// `achievements-editor.js` reads each rendered option's data attributes so the
// Swift enum, the dropdown, and the JS can't drift.  The switch is exhaustive
// on purpose: adding a signal fails to compile until it gets a presentation
// here, instead of rendering blank.
//
// Everything the JS needs about a signal rides on the option, INCLUDING the
// accessible name of its reference input and the row field the reference
// serializes to. An earlier draft kept those two in a JS table, which is the
// drift the data attributes exist to prevent: a new ref kind would have
// rendered its input, gone unlabelled, and been silently dropped on save.

import Core

/// Which named artifact a condition points at.
///
/// This began as an `isTest` boolean, which is the shape that admits exactly
/// one referencing signal.  `itemsCovered` scopes itself by suite SECTION, so
/// the second one arrived — and a second boolean would have let both be true at
/// once.  A closed kind cannot express that state at all, and it is the one
/// switch that derives every per-reference fact below.
enum AchievementSignalRefKind {
    /// No reference: the condition compares a value (the common case).
    case none
    /// A test the suite contains, named by script filename or display name.
    case test
    /// A suite section, chosen from the sections the assignment has.
    case section

    /// The `ConditionRow` field this reference serializes to.  The JS writes
    /// `row[refField] = value` rather than branching on a kind name, so a third
    /// kind lands in the right field with no JS edit.
    var refField: String {
        switch self {
        case .none: return ""
        case .test: return "testRef"
        case .section: return "sectionRef"
        }
    }

    /// Which input the editor shows: a free-text box, or a picker populated
    /// from the assignment's own suite sections.
    ///
    /// A section id is an opaque UUID that no page ever displays, so free text
    /// asked an author to type something they could not obtain — and then
    /// echoed the UUID back at them in the rule summary.  Choosing one of a
    /// known set is a `select` everywhere else in this editor.
    var control: String {
        switch self {
        case .none: return ""
        case .test: return "text"
        case .section: return "sections"
        }
    }

    /// The input's accessible name.  A placeholder is a hint, not a name.
    var label: String {
        switch self {
        case .none: return ""
        case .test: return "Test"
        case .section: return "Suite section"
        }
    }

    /// Placeholder for the text control; empty for the others.
    var placeholder: String {
        switch self {
        case .none, .section: return ""
        case .test: return "secrettest_x.py"
        }
    }
}

/// One condition signal as the editor presents it.
struct AchievementSignalOption: Encodable {
    /// Raw `AchievementSignal` value, the condition's `signal` field.
    let value: String
    /// Short label shown in the signal dropdown.
    let label: String
    /// One-line explanation of the signal.  Not currently rendered anywhere —
    /// the dropdown shows `label` alone — but it is what the rule means, and
    /// `AchievementKindPresentationTests` holds every signal to having one.
    let detail: String
    /// Unit suffix shown next to the value input ("%", "ms", "pts", or "").
    let unit: String
    /// Space-separated `AchievementScope` values this signal may be used under
    /// — the same shape (and the same idiom) as the editor's `data-scope`
    /// attributes, so the dropdown can hide an option the save would refuse.
    let scopes: String
    /// Which input this signal's reference needs, if any: "" | "text" | "sections".
    let refControl: String
    /// The `ConditionRow` field the reference serializes to.
    let refField: String
    /// Accessible name for that input.
    let refLabel: String
    /// Placeholder for a "text" reference input.
    let refPlaceholder: String
    /// True when the reference REPLACES the comparator/value pair rather than
    /// accompanying it.  `testPass` has nothing to compare; `itemsCovered`
    /// compares a count AND scopes it, so it needs both.
    let refReplacesValue: Bool
}

enum AchievementSignalPresentation {

    static var all: [AchievementSignalOption] {
        AchievementSignal.allCases.map(option(for:))
    }

    private static func option(for signal: AchievementSignal) -> AchievementSignalOption {
        switch signal {
        case .grade:
            return make(signal, "Grade", "assignment grade", unit: "%", ref: .none)
        case .attempts:
            return make(signal, "Attempts", "attempt number", unit: "", ref: .none)
        case .executionTimeMs:
            return make(signal, "Run time", "total execution time", unit: "ms", ref: .none)
        case .gradeJumpPercent:
            return make(
                signal, "Grade jump", "gain vs the previous attempt", unit: "pts", ref: .none)
        case .testPass:
            return make(
                signal, "Test passes", "a specific test passes", unit: "", ref: .test,
                refReplacesValue: true)
        case .itemsCovered:
            return make(
                signal, "Items covered",
                "distinct tests the class has collectively passed", unit: "", ref: .section)
        case .standing:
            return make(signal, "Standing", "place in the round robin standings (1 = first)", unit: "", ref: .none)
        case .matchesWon:
            return make(signal, "Matches won", "matches the latest submission won", unit: "", ref: .none)
        case .classCoverage:
            return make(
                signal, "Class coverage",
                "share of the reference the class's combined contributions cover", unit: "%",
                ref: .none)
        }
    }

    private static func make(
        _ signal: AchievementSignal, _ label: String, _ detail: String,
        unit: String, ref: AchievementSignalRefKind, refReplacesValue: Bool = false
    ) -> AchievementSignalOption {
        AchievementSignalOption(
            value: signal.rawValue, label: label, detail: detail, unit: unit,
            scopes: signal.allowedScopes.map(\.rawValue).joined(separator: " "),
            refControl: ref.control, refField: ref.refField, refLabel: ref.label,
            refPlaceholder: ref.placeholder, refReplacesValue: refReplacesValue)
    }
}

// MARK: - Record dimensions

/// One `RecordDimension` as the editor and the MCP schema present it.
struct RecordDimensionOption: Encodable {
    /// Raw `RecordDimension` value.
    let value: String
    /// Short label for the "Ranked by" select.
    let label: String
    /// One clause for the MCP schema's description of the dimension.
    let detail: String
}

/// Single source of truth for how a record's ranking dimension is named — the
/// same discipline as `AchievementSignalPresentation`, for the same reason: the
/// "Ranked by" select, the JS rule summary and the MCP `recordDimension` enum
/// were each a hand-typed copy of the four cases, and none of them could see a
/// fifth. Every surface now renders from `all`; `RecordDimensionCoverageTests`
/// holds them to it.
enum RecordDimensionPresentation {

    static var all: [RecordDimensionOption] {
        RecordDimension.allCases.map(option(for:))
    }

    private static func option(for dimension: RecordDimension) -> RecordDimensionOption {
        switch dimension {
        case .firstToSubmit:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "First to submit",
                detail: "first submission of any kind")
        case .firstToSolve:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "First to 100%", detail: "first to 100%")
        case .fastest:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "Fastest run",
                detail: "lowest execution time at 100%")
        case .shortest:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "Fewest attempts",
                detail: "FEWEST ATTEMPTS to reach 100% (a legacy name — it does not measure "
                    + "solution length)")
        case .highestMetric:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "Highest metric",
                detail: "highest ranking `metric` any submission reported (a class activity's "
                    + "leaderboard record; not gated on 100%)")
        case .champion:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "Hill champion",
                detail: "the current holder of a king-of-the-hill activity's hill (moves to "
                    + "whoever takes it; not gated on 100%)")
        case .tournamentWinner:
            return RecordDimensionOption(
                value: dimension.rawValue, label: "Standings leader",
                detail: "the current leader of a round robin's standings (moves with the "
                    + "standings; not gated on 100%)")
        }
    }

    /// "firstToSolve = first to 100%; firstToSubmit = …" — the MCP schema's
    /// description, derived so it cannot stop short of the enum.
    static var schemaDescription: String {
        "record only: the dimension students are ranked on. "
            + all.map { "\($0.value) = \($0.detail)" }.joined(separator: "; ") + "."
    }
}
