// Core/LTIRoleMapping.swift
//
// Maps the `roles` claim of an LTI 1.3 launch to a per-course `CourseRole`
// (docs/lti-1-3.md "Role mapping"). Pure, so the launch path and its tests
// share one answer.

import Foundation

/// The mapping from LTI 1.3 membership roles to `CourseRole`.
///
/// Only CONTEXT roles grant a course role. Institution and system roles
/// describe the person, not the person in this course, so an institution
/// "Instructor" who takes a course as a learner stays a student there.
public enum LTIRoleMapping {
    /// The context-role vocabulary prefix (LIS v2 membership).
    static let membershipPrefix = "http://purl.imsglobal.org/vocab/lis/v2/membership"

    /// The course role that `roles` grants, or nil when no role maps.
    ///
    /// A teaching-assistant sub-role wins over the Instructor principal role:
    /// the specification sends both for a TA, so "highest role wins" alone
    /// would make every TA an instructor.
    public static func courseRole(forRoles roles: [String]) -> CourseRole? {
        let parsed = roles.compactMap(contextRole(from:))
        if parsed.contains(where: \.isTeachingAssistant) {
            return .ta
        }
        return parsed.compactMap(\.courseRole).max()
    }

    /// A context role split into its principal role and optional sub-role.
    struct ContextRole: Equatable {
        let principal: String
        let subRole: String?

        var isTeachingAssistant: Bool {
            subRole == "TeachingAssistant" || subRole == "Grader"
                || principal == "TeachingAssistant"
        }

        var courseRole: CourseRole? {
            switch principal {
            case "Instructor", "Administrator", "ContentDeveloper": .instructor
            case "Learner": .student
            default: nil
            }
        }
    }

    /// Parses one role string. Accepts the full URI forms
    /// (`…/membership#Instructor`, `…/membership/Instructor#TeachingAssistant`)
    /// and the simple context-role names that LTI 1.3 still permits
    /// (`Instructor`). Returns nil for institution, system and unknown roles.
    static func contextRole(from role: String) -> ContextRole? {
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(membershipPrefix) else {
            // A bare simple name is a context role; any other URI is not.
            guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/") else {
                return nil
            }
            return ContextRole(principal: trimmed, subRole: nil)
        }
        let rest = trimmed.dropFirst(membershipPrefix.count)
        if rest.hasPrefix("#") {
            let principal = String(rest.dropFirst())
            return principal.isEmpty ? nil : ContextRole(principal: principal, subRole: nil)
        }
        guard rest.hasPrefix("/") else { return nil }
        let parts = rest.dropFirst().split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return ContextRole(principal: parts[0], subRole: parts[1])
    }
}
