// Core/AssignmentType.swift
//
// What kind of graded work an assignment is: an Assignment for marks, a Lab
// graded in the browser for participation, or a live Class activity
// (docs/assignment-types.md). The author declares it. Nothing infers it, except
// `derivedDeclaration` at the boundaries that create an assignment row, and
// each of those records the result at once.

/// The kind of graded work an assignment is. The raw value is stored on the
/// assignment, so it is append-only.
public enum AssignmentType: String, CaseIterable, Codable, Sendable {
    /// Individual work for marks. Graded by the native worker, so its secret
    /// tests never reach the student.
    case assignment
    /// Work the whole class does at once. Graded in the student browser for a
    /// participation grade, where secret tests are readable.
    case lab
    /// Live, synchronous content that is not worth a grade. Carries an
    /// `activity` block.
    case classActivity

    /// The name an instructor reads in the Type select.
    public var displayName: String {
        switch self {
        case .assignment: "Assignment"
        case .lab: "Lab"
        case .classActivity: "Class activity"
        }
    }

    /// The display name with its indefinite article, for a sentence:
    /// "an Assignment", "a Lab", "a Class activity".
    public var withArticle: String {
        switch self {
        case .assignment: "an Assignment"
        case .lab: "a Lab"
        case .classActivity: "a Class activity"
        }
    }

    // MARK: - The rules (docs/assignment-types.md, "What the type controls")

    /// The grading mode an assignment of this type gets on create when its
    /// author names none: the student browser for a Lab, the native worker
    /// otherwise. An upload-only language still forces the worker.
    public var defaultGradingMode: GradingMode {
        self == .lab ? .browser : .worker
    }

    /// Whether this type may be graded in the student browser. An Assignment
    /// may not: browser grading ships its release and secret tests to every
    /// student (decision 1).
    public var allowsBrowserGrading: Bool {
        self != .assignment
    }

    /// Whether this type must carry an `activity` block (decision 3).
    public var requiresActivity: Bool {
        self == .classActivity
    }

    /// Whether grades of this type go to the institution's LMS, through
    /// BrightSpace Valence or LTI AGS. A Class activity's points stay in
    /// Chickadee, for the leaderboard and achievements (decision 2).
    public var pushesGradesToLMS: Bool {
        self != .classActivity
    }

    /// Whether a student may spend slip days on this type. A Class activity's
    /// live window replaces a deadline (decision 2).
    public var allowsSlipDays: Bool {
        self != .classActivity
    }

    /// The type an assignment created from `manifest` declares when its
    /// creator names none, and the type the one-time backfill recorded for the
    /// assignments that existed before the field (docs/assignment-types.md,
    /// "Backfill"). Browser grading means a Lab, even when the Lab carries an
    /// activity; otherwise an activity block means a Class activity. It reads
    /// the effective grading mode, so an upload-only setup is never a Lab
    /// here. Never a title.
    public static func derivedDeclaration(manifest: TestProperties) -> AssignmentType {
        if manifest.effectiveGradingMode == .browser { return .lab }
        if manifest.activity != nil { return .classActivity }
        return .assignment
    }
}
