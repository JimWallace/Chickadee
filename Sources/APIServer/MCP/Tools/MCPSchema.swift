// APIServer/MCP/Tools/MCPSchema.swift
//
// Shared JSON-Schema fragments for the MCP tool catalog (#1121).  The same
// hand-written property blocks appeared dozens of times across the tool
// files (`assignmentPublicID` ~29×, the tier enum 7×, `courseCode` 5×), so a
// wording fix or constraint change meant a fan-out edit.  Tools reference
// these constants/builders instead; anything tool-specific (a bespoke
// description, an unusual constraint) stays inline in the tool.

import Core

enum MCPSchema {
    // MARK: - Bare-typed properties (output schemas)

    /// `{"type": "string"}` — output-schema property with no description.
    static let string: JSONValue = .object(["type": .string("string")])
    /// `{"type": "integer"}`
    static let integer: JSONValue = .object(["type": .string("integer")])
    /// `{"type": "boolean"}`
    static let boolean: JSONValue = .object(["type": .string("boolean")])
    /// `{"type": "number"}`
    static let number: JSONValue = .object(["type": .string("number")])

    // MARK: - Shared domain properties

    /// The input property nearly every assignment-scoped tool declares.
    static let assignmentPublicID: JSONValue = .object([
        "type": .string("string"),
        "description": .string("The assignment's 6-character public ID."),
    ])

    /// The input property the course-scoped tools declare.
    static let courseCode: JSONValue = .object([
        "type": .string("string"),
        "description": .string("The course code, e.g. \"CS136\"."),
    ])

    /// A test-tier enum property.  The student-visible tiers by default; tools
    /// that also accept support files pass `TestTierValues.withSupport`.
    static func tierEnum(
        _ values: [String] = TestTierValues.tiers, description: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
        ]
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }

    // MARK: - Object builder

    /// A JSON-Schema object with the given properties.  `additionalProperties`
    /// defaults to false (the catalog's convention for input schemas); pass
    /// nil to omit the key (the convention for output schemas).
    static func object(
        properties: [String: JSONValue],
        required: [String] = [],
        additionalProperties: Bool? = false
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.map { .string($0) })
        }
        if let additionalProperties {
            fields["additionalProperties"] = .bool(additionalProperties)
        }
        return .object(fields)
    }
}

/// The tier strings the schema enums advertise, DERIVED from `TestTier` rather
/// than listed.
///
/// It was listed, and it listed a fourth tier — `student` — that `TestTier` has
/// never had, so every tool advertising this enum accepted a value its own
/// parser then rejected. Deriving it means the schema cannot offer a tier the
/// server will refuse. See `MCPTierProse` for the prose renderings of the same
/// set.
enum TestTierValues {
    /// The graded, student-visible tiers.
    static var tiers: [String] { TestTier.allCases.map(\.rawValue) }
    /// A bundled file that is never run. Not a `TestTier` case, so it is the one
    /// value here that cannot be derived.
    static let supportPseudoTier = "support"
    /// The tiers plus the pseudo-tier `support`.
    static var withSupport: [String] { tiers + [supportPseudoTier] }
}

/// The achievement condition signals a schema enum offers, derived from
/// `AchievementSignal.allCases` for the same reason `TestTierValues` is derived
/// from `TestTier.allCases`: a hand-typed enum can offer a value the parser
/// refuses, or omit one it accepts. See `MCPAchievementSignalProse` for the
/// prose renderings of the same set.
enum AchievementSignalValues {
    static var all: [String] { AchievementSignal.allCases.map(\.rawValue) }
}
