// APIServer/Routes/Web/EnrollCSVHelper.swift
//
// Shared utilities for CSV-based bulk enrollment, used by both AdminRoutes
// and AssignmentRoutes so the logic and result view context stay in sync.

import Foundation

/// Parses a flat list of usernames from a CSV upload.
///
/// Recognised shapes:
/// - **Single-column** (one username per line, optional `username` header).
/// - **Multi-column with a header**: scans every header cell for a known
///   username keyword and uses that column.  Falls back to the first
///   column when no username header is found.
/// - **Brightspace / D2L gradebook export** (`OrgDefinedId,Username,
///   End-of-Line Indicator`): the `OrgDefinedId` column carries values
///   like `#174667.teststudent1`; the leading `#<digits>.` prefix is
///   stripped so the bare username matches Chickadee accounts.
///
/// Surrounding whitespace and quotes are stripped from each cell.  Blank
/// cells and a `#` end-of-line marker are filtered out.
func parseUsernamesFromCSV(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else {
        return []
    }

    var lines = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let headerKeywords: Set<String> = [
        "username", "user", "login",
        "id", "studentid", "userid", "loginid",
        "orgdefinedid",                          // Brightspace gradebook export
    ]
    func normaliseHeaderCell(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // Detect a header row + pick which column carries the username.
    // Default: first column (single-column files, headerless dumps).
    var usernameColumn = 0
    if let firstLine = lines.first {
        let cells = firstLine.components(separatedBy: ",").map(normaliseHeaderCell)
        // First cell matches a known keyword → header row.  Drop it.
        if let first = cells.first, headerKeywords.contains(first) {
            lines.removeFirst()
            // Multi-column header: prefer a "username" column over the
            // first one if present.  Brightspace's OrgDefinedId / Username
            // pair is the motivating case — we want the friendlier
            // Username value when both are populated.
            if let usernameIdx = cells.firstIndex(of: "username"),
               usernameIdx < cells.count {
                usernameColumn = usernameIdx
            }
        }
    }

    // Strip the Brightspace `#<digits>.` OrgDefinedId prefix so values
    // like `#174667.teststudent1` resolve to bare `teststudent1`.
    // Conservative: only fires when the value starts with `#` and the
    // prefix is digits-and-dot — random `#`-prefixed usernames pass
    // through unchanged.
    func stripBrightspacePrefix(_ s: String) -> String {
        guard s.hasPrefix("#") else { return s }
        let afterHash = s.dropFirst()
        guard let dotIdx = afterHash.firstIndex(of: "."),
              afterHash[..<dotIdx].allSatisfy(\.isNumber)
        else { return s }
        return String(afterHash[afterHash.index(after: dotIdx)...])
    }

    return lines.compactMap { line -> String? in
        let cells = line.components(separatedBy: ",")
        guard usernameColumn < cells.count else { return nil }
        let raw = cells[usernameColumn]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        // Brightspace's "End-of-Line Indicator" column is literally `#` —
        // when the chosen column lands on that, drop it.  Bare `#` is
        // never a real username.
        guard !raw.isEmpty, raw != "#" else { return nil }
        let stripped = stripBrightspacePrefix(raw)
        return stripped.isEmpty ? nil : stripped
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
    /// URL the back-button should link to (admin course page or /instructor).
    let returnURL: String
    // Precomputed for easy Leaf truthiness check.
    var hasNotFound: Bool { !notFoundUsernames.isEmpty }
    var notFoundCount: Int { notFoundUsernames.count }
}
