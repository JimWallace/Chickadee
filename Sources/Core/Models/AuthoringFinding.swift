// Core/Models/AuthoringFinding.swift
//
// One problem found in an assignment's authoring content (#2747). The rule-based
// authoring checks report in this format, and so do the model reviewers that
// read the same content, so one report can merge both kinds of finding.

/// One problem in an assignment's authoring content, from a rule-based check or
/// from a reviewer.
public struct AuthoringFinding: Codable, Sendable, Equatable {
    /// How much the problem matters. Cases are declared most severe first, and
    /// a report sorts on that order.
    public enum Severity: String, Codable, Sendable, Equatable, CaseIterable {
        /// The assignment grades wrongly or cannot be completed.
        case error
        /// Probably a mistake. The author should look.
        case warning
        /// Often deliberate. Worth confirming.
        case info

        /// The position in `allCases`, so that `error` sorts first.
        public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    }

    /// What produced the finding.
    public enum Source: String, Codable, Sendable, Equatable, CaseIterable {
        /// A rule-based check: the same content always gives the same finding.
        case check
        /// A model reviewer: a judgement, which the author may reject.
        case reviewer
    }

    /// Where in the assignment the problem is.
    public struct Location: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
            /// The assignment as a whole. `reference` is nil.
            case assignment
            /// One suite entry. `reference` is its script filename.
            case suiteItem
            /// One starter-notebook cell. `reference` is its 0-based index.
            case notebookCell
            /// One personalization input. `reference` is its name.
            case input
            /// One support file or dataset. `reference` is its filename.
            case file
        }

        public let kind: Kind
        public let reference: String?

        public init(kind: Kind, reference: String? = nil) {
            self.kind = kind
            self.reference = reference
        }

        public static let assignment = Location(kind: .assignment)

        public static func suiteItem(_ script: String) -> Location {
            Location(kind: .suiteItem, reference: script)
        }

        public static func input(_ name: String) -> Location {
            Location(kind: .input, reference: name)
        }
    }

    /// The stable id of the check or reviewer, for example
    /// `tiers.noPublicTest` or `reviewer.voice`.
    public let checkID: String
    public let source: Source
    public let severity: Severity
    public let location: Location
    /// What is wrong, in one or two sentences.
    public let message: String
    /// What to change, when there is one clear fix.
    public let suggestedFix: String?

    public init(
        checkID: String,
        source: Source,
        severity: Severity,
        location: Location,
        message: String,
        suggestedFix: String? = nil
    ) {
        self.checkID = checkID
        self.source = source
        self.severity = severity
        self.location = location
        self.message = message
        self.suggestedFix = suggestedFix
    }
}
