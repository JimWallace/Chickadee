// LoadTest/StudentSession.swift
//
// A simulated student's signed-in session, and its line in the sessions file
// that later runs reuse.

/// A simulated student's signed-in session.
struct StudentSession: Sendable, Equatable {
    let username: String
    let cookieHeader: String

    /// One line of a sessions file: the username, a tab, the Cookie header.
    var line: String { "\(username)\t\(cookieHeader)" }

    init(username: String, cookieHeader: String) {
        self.username = username
        self.cookieHeader = cookieHeader
    }

    init?(line: Substring) {
        let parts = line.split(separator: "\t", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(username: String(parts[0]), cookieHeader: String(parts[1]))
    }
}
