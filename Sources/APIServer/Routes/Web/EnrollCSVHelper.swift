// APIServer/Routes/Web/EnrollCSVHelper.swift
//
// Shared utilities for CSV-based bulk enrollment, used by both AdminRoutes
// and AssignmentRoutes so the logic and result view context stay in sync.

import Foundation
import Fluent
import Vapor

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
    /// Usernames the parser produced that don't yet have an APIUser row;
    /// recorded as pre-enrollments and resolved on first SSO login.
    let preEnrolledCount: Int
    let alreadyEnrolledCount: Int
    /// Usernames the parser rejected (failed shape validation) — surfaced
    /// to the instructor so they can fix the CSV.
    let rejectedUsernames: [String]
    /// URL the back-button should link to (admin course page or /instructor).
    let returnURL: String
    // Precomputed for easy Leaf truthiness check.
    var hasRejected: Bool { !rejectedUsernames.isEmpty }
    var rejectedCount: Int { rejectedUsernames.count }
    var hasPreEnrolled: Bool { preEnrolledCount > 0 }
}

// MARK: - Bulk-enroll execution

/// Validates that a parsed username is safe to record as a pending
/// pre-enrollment.  Conservative: matches the typical shape of UWaterloo
/// quest names plus common email/identifier formats; rejects empty,
/// over-long, or control-char-laden values.  The bulk-enroll handler
/// surfaces rejected names so the instructor can clean the CSV.
func isAcceptableUsernameForEnrollment(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 64 else { return false }
    let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@+")
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
}

struct EnrollUsernamesResult {
    /// Existing users freshly added to this course's roster.
    let enrolledCount: Int
    /// Usernames recorded as pending pre-enrollments (no APIUser yet).
    let preEnrolledCount: Int
    /// Existing users already on the roster; left untouched.
    let alreadyEnrolledCount: Int
    /// Usernames the parser produced that we refused to record.
    let rejectedUsernames: [String]
}

/// Enrolls `usernames` in `courseID`, recording a pre-enrollment row for
/// any username that has no matching APIUser yet.  Idempotent: re-running
/// with the same CSV makes no further changes.  The login flow itself is
/// untouched — pre-enrollments resolve in a separate post-login step
/// (`resolvePendingPreEnrollments`), so a bug in this helper cannot block
/// any student from signing in.
func enrollUsernamesInCourse(
    _ usernames: [String],
    courseID: UUID,
    on db: Database
) async throws -> EnrollUsernamesResult {
    var seen = Set<String>()
    let uniqueUsernames = usernames.filter { seen.insert($0).inserted }

    let usernameSet = Set(uniqueUsernames)
    let allUsers = try await APIUser.query(on: db).all()
    var byUsername: [String: APIUser] = [:]
    for u in allUsers where usernameSet.contains(u.username) {
        byUsername[u.username] = u
    }

    let existingEnrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    let alreadyEnrolledUserIDs = Set(existingEnrollments.map { $0.userID })

    let existingPreEnrollments = try await APIPreEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    let alreadyPreEnrolledUsernames = Set(existingPreEnrollments.map { $0.username })

    var enrolledCount        = 0
    var preEnrolledCount     = 0
    var alreadyEnrolledCount = 0
    var rejected:    [String] = []

    for name in uniqueUsernames {
        if let user = byUsername[name] {
            guard let userID = user.id else { continue }
            if alreadyEnrolledUserIDs.contains(userID) {
                alreadyEnrolledCount += 1
            } else {
                let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
                try await enrollment.save(on: db)
                enrolledCount += 1
            }
            continue
        }

        guard isAcceptableUsernameForEnrollment(name) else {
            rejected.append(name)
            continue
        }

        // Already pre-enrolled in this course?  Idempotent skip.
        if alreadyPreEnrolledUsernames.contains(name) {
            alreadyEnrolledCount += 1
            continue
        }

        let pending = APIPreEnrollment(courseID: courseID, username: name)
        try await pending.save(on: db)
        preEnrolledCount += 1
    }

    return EnrollUsernamesResult(
        enrolledCount:        enrolledCount,
        preEnrolledCount:     preEnrolledCount,
        alreadyEnrolledCount: alreadyEnrolledCount,
        rejectedUsernames:    rejected.sorted()
    )
}

/// Resolves any pending pre-enrollments for `user`: turns each pending
/// (course, username) into a real `APICourseEnrollment` and deletes the
/// pre-enrollment row.  Called after login (SSO and local) returns a
/// successfully authenticated user.  Failures are intentionally
/// swallowed and logged — they cannot block login.
func resolvePendingPreEnrollments(
    for user: APIUser,
    db: Database,
    logger: Logger
) async {
    guard let userID = user.id else { return }
    let username = user.username

    do {
        let pending = try await APIPreEnrollment.query(on: db)
            .filter(\.$username == username)
            .all()
        guard !pending.isEmpty else { return }

        // Existing enrollments for this user — skip duplicate inserts so
        // a unique-constraint violation can't kill the resolution loop.
        let existing = try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == userID)
            .all()
        let existingCourseIDs = Set(existing.map { $0.$course.id })

        for row in pending {
            let courseID = row.$course.id
            if !existingCourseIDs.contains(courseID) {
                let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
                do {
                    try await enrollment.save(on: db)
                } catch {
                    logger.warning("Pre-enrollment resolve: failed to enroll \(username) in \(courseID): \(error)")
                    continue
                }
            }
            do {
                try await row.delete(on: db)
            } catch {
                logger.warning("Pre-enrollment resolve: failed to delete pending row for \(username) in \(courseID): \(error)")
            }
        }
    } catch {
        // Swallow — the user is already authenticated; missing roster
        // membership is a UX bug, not an auth blocker.
        logger.warning("Pre-enrollment resolve query failed for \(username): \(error)")
    }
}
