// APIServer/Routes/Web/AssignmentHelpers.swift
//
// Small free functions used by the instructor assignment routes that
// don't belong to a more focused helper file.  The bulk of what used to
// live here was split out per issue #442 into:
//
//   - AssignmentDraftHelpers.swift
//   - AssignmentRequirementHelpers.swift
//   - AssignmentSlugHelpers.swift
//   - ManifestFileHelpers.swift
//   - MultipartHelpers.swift
//   - NotebookScaffoldHelpers.swift
//   - RunnerValidationHelpers.swift
//   - SuiteRowHelpers.swift
//   - TestSetupZipHelpers.swift
//
// What remains: section-ID resolution, due-date parsing/formatting,
// human-name splitting, return-path sanitization, deadline-override
// helpers, sort-order allocation, grade-extraction helpers, CSV
// escaping, and student-ID name inference.

import Core
import Fluent
import Foundation
import Vapor

/// Validates a sectionID string (UUID) against the given course and returns the UUID if valid.
/// Returns nil for absent, empty, or "none" values (meaning "ungrouped").
func resolveSectionID(_ raw: String?, courseID: UUID, db: Database) async throws -> UUID? {
    guard let raw, !raw.isEmpty, raw.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: raw) else {
        throw WebAssignmentError.invalidParameter(name: "sectionID", reason: "Invalid sectionID format.")
    }
    guard let section = try await APICourseSection.find(uuid, on: db),
        section.courseID == courseID
    else {
        // Section not found or belongs to a different course — silently ignore.
        return nil
    }
    return uuid
}

func parseDueDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: raw) { return d }

    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.date(from: raw)
}

func waterlooDateTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_CA")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt
}

func splitHumanName(_ raw: String?) -> (surname: String, givenNames: String)? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(",") {
        let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let surname = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let givenNames =
            parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (
            surname.isEmpty ? "—" : surname,
            givenNames.isEmpty ? "—" : givenNames
        )
    }

    let parts = trimmed.split(whereSeparator: \.isWhitespace)
    guard !parts.isEmpty else { return nil }
    if parts.count == 1 {
        return ("—", String(parts[0]))
    }

    let surname = String(parts.last ?? "")
    let givenNames = parts.dropLast().joined(separator: " ")
    return (
        surname.isEmpty ? "—" : surname,
        givenNames.isEmpty ? "—" : givenNames
    )
}

func sanitizedAssignmentReturnPath(
    _ raw: String?,
    assignmentIDRaw: String,
    fallbackPath: String
) -> String {
    guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
        return fallbackPath
    }

    let expectedPrefix = "/instructor/\(assignmentIDRaw)"
    guard path == expectedPrefix || path.hasPrefix(expectedPrefix + "/") else {
        return fallbackPath
    }
    return path
}

func dueAtLocalInputString(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.string(from: date)
}

func deadlineOverrideValueForInstructorOpen(
    dueAt: Date?,
    now: Date = Date()
) -> Bool {
    guard let dueAt else { return false }
    return dueAt <= now
}

func normalizedDeadlineOverrideAfterDueDateChange(
    dueAt: Date?,
    existingOverride: Bool
) -> Bool {
    guard let dueAt else { return false }
    return dueAt <= Date() ? existingOverride : false
}

func nextAssignmentSortOrder(req: Request) async throws -> Int {
    let maxOrder =
        try await APIAssignment.query(on: req.db)
        .all()
        .compactMap(\.sortOrder)
        .max() ?? 0
    return maxOrder + 1
}

/// Returns the earned points for a submission result, suitable for LEARN-style CSV export.
/// Tries Double first (for fractional points), falls back to Int for older results.
/// When earnedPoints/totalPoints are absent, falls back to passCount.
func gradePointsFromCollectionJSON(_ collectionJSON: String) -> Double? {
    guard let data = collectionJSON.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    // Prefer weighted points when present (non-nil and non-zero totalPoints).
    let totalPoints = (root["totalPoints"] as? Double) ?? (root["totalPoints"] as? Int).map(Double.init)
    if let total = totalPoints, total > 0 {
        let earned = (root["earnedPoints"] as? Double) ?? (root["earnedPoints"] as? Int).map(Double.init)
        if let e = earned { return e }
    }
    // Fall back to pass count for old results.
    let passCount = (root["passCount"] as? Double) ?? (root["passCount"] as? Int).map(Double.init)
    return passCount
}

/// Returns the total possible points recorded on a submission result, used as
/// the denominator when converting a percent grade override into BrightSpace
/// points.  Nil when the result predates weighted grading (no `totalPoints`).
func gradeTotalPointsFromCollectionJSON(_ collectionJSON: String) -> Double? {
    guard let data = collectionJSON.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    let totalPoints = (root["totalPoints"] as? Double) ?? (root["totalPoints"] as? Int).map(Double.init)
    if let total = totalPoints, total > 0 { return total }
    return nil
}

func gradePercentFromCollectionJSON(_ collectionJSON: String) -> Int? {
    guard let data = collectionJSON.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    // Prefer weighted points when present (non-nil and non-zero totalPoints).
    if let earnedPoints = root["earnedPoints"] as? Int,
        let totalPoints = root["totalPoints"] as? Int,
        totalPoints > 0
    {
        return Int((Double(earnedPoints) / Double(totalPoints) * 100).rounded())
    }
    // Fall back to unweighted count for old results.
    guard let passCount = root["passCount"] as? Int,
        let totalTests = root["totalTests"] as? Int,
        totalTests > 0
    else { return nil }
    return Int((Double(passCount) / Double(totalTests) * 100).rounded())
}

func csvEscaped(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

func inferNameFromStudentID(_ studentID: String) -> (surname: String, givenNames: String) {
    let raw = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return ("—", "—") }

    if let parsed = splitHumanName(raw), raw.contains(",") { return parsed }
    return ("—", "—")
}
