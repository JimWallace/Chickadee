// Core/AssignmentConcept.swift
//
// The lab concept an instructor may tag an assignment with, so that full
// marks on it earn that concept's ring (docs/student-wardrobe.md, "Concept
// rings"). The tag is set by hand on the assignment edit page. Nothing infers
// it from a title or an order.

/// The concept an assignment teaches, for the wardrobe's concept rings. The
/// raw value is stored on the assignment, so it is append-only.
public enum AssignmentConcept: String, CaseIterable, Codable, Sendable {
    case numbers, conditionals, loops, functions, binary, healthData

    /// The name an instructor reads in the select, and a student reads in the
    /// ring's how-to-earn text (lowercased).
    public var displayName: String {
        switch self {
        case .numbers: "Variables & numbers"
        case .conditionals: "Conditionals"
        case .loops: "Loops"
        case .functions: "Functions"
        case .binary: "Data representation"
        case .healthData: "Health data"
        }
    }

    /// The ring as a sentence names it: "the Ouroboros ring", and "the Life
    /// ring" for the one whose name already ends in "ring".
    public var ringPhrase: String {
        let name = ring.displayName
        return name.hasSuffix(" ring") ? "the \(name)" : "the \(name) ring"
    }

    /// The ring that full marks on an assignment with this concept earns.
    public var ring: AvatarBorder {
        switch self {
        case .numbers: .lifering
        case .conditionals: .greenlight
        case .loops: .ouroboros
        case .functions: .function
        case .binary: .binary
        case .healthData: .pulse
        }
    }
}
