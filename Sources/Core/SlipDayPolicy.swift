// Core/SlipDayPolicy.swift
//
// Course-level slip-day policy (#1228): a per-student budget of self-serve
// deadline extensions.  Each slip day extends one assignment's deadline by
// `extensionHours` from the *original* deadline, and days stack — a student
// may put one day each on two assignments, or several on one.
//
// The three fields mirror three nullable columns on `courses`
// (`slip_days_enabled`, `slip_days_per_student`, `slip_day_extension_hours`);
// `resolve` maps missing values to the defaults so pre-existing courses are
// unaffected (disabled) and a course that enables the feature starts at the
// documented 2 × 24 h.

import Foundation

public struct SlipDayPolicy: Codable, Sendable, Equatable {
    /// Whether students in the course may spend slip days at all.
    public let enabled: Bool
    /// The course-wide per-student budget (before any per-student adjustment).
    public let daysPerStudent: Int
    /// Hours of extension one slip day buys, counted from the original
    /// deadline (a second stacked day extends to 2 × this, and so on).
    public let extensionHours: Int

    public static let defaultDaysPerStudent = 2
    public static let defaultExtensionHours = 24

    public init(enabled: Bool, daysPerStudent: Int, extensionHours: Int) {
        self.enabled = enabled
        self.daysPerStudent = daysPerStudent
        self.extensionHours = extensionHours
    }

    /// Resolves stored (nullable) course columns into an effective policy.
    /// Nil means "never configured": disabled, with the defaults pre-filled
    /// for the moment the feature is switched on.  Values are clamped so a
    /// hand-edited row can't produce a negative budget or a zero-length day.
    public static func resolve(
        enabled: Bool?, daysPerStudent: Int?, extensionHours: Int?
    ) -> SlipDayPolicy {
        SlipDayPolicy(
            enabled: enabled ?? false,
            daysPerStudent: max(daysPerStudent ?? defaultDaysPerStudent, 0),
            extensionHours: max(extensionHours ?? defaultExtensionHours, 1)
        )
    }
}
