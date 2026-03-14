// APIServer/Routes/Web/EnrollCSVHelper.swift
//
// Shared utilities for CSV-based bulk enrollment, used by both AdminRoutes
// and AssignmentRoutes so the logic and result view context stay in sync.

import Foundation

/// Parses a flat list of usernames from a CSV upload.
/// - Takes the first column of every non-blank line.
/// - Strips surrounding quotes and whitespace.
/// - Auto-detects and skips a header row when the first column matches a known keyword.
func parseUsernamesFromCSV(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else {
        return []
    }

    var lines = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // Skip an obvious header row.
    if let firstLine = lines.first {
        let firstCol = firstLine
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            ?? ""
        let headerKeywords = ["username", "user", "login", "id", "studentid", "userid", "loginid"]
        if headerKeywords.contains(firstCol) {
            lines.removeFirst()
        }
    }

    // Extract first column, strip surrounding quotes/whitespace.
    return lines.compactMap { line -> String? in
        let col = line
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let col, !col.isEmpty else { return nil }
        return col
    }
}

/// Context for the shared `admin-enroll-csv-result` view, rendered by both
/// admin and instructor CSV enrollment handlers.
struct EnrollCSVResultContext: Encodable {
    let currentUser: CurrentUserContext?
    let courseCode: String
    let courseName: String
    let enrolledCount: Int
    let alreadyEnrolledCount: Int
    let notFoundUsernames: [String]
    /// URL the back-button should link to (admin course page or /assignments).
    let returnURL: String
    // Precomputed for easy Leaf truthiness check.
    var hasNotFound: Bool { !notFoundUsernames.isEmpty }
    var notFoundCount: Int { notFoundUsernames.count }
}
