// APIServer/Services/GroupRosterCSV.swift
//
// Reads a CSV file of students and their groups (docs/lab-groups.md, slice 1).
// Two shapes are accepted:
//
//   * Two columns with no header: `username,group`.
//   * A header row that names a username column and a group column, in any
//     order, among other columns. The LEARN Groups export is this shape: its
//     "Username" and "Group Name" columns are read and the rest are ignored.
//
// A header cell is matched after it is lowercased and its spaces and
// underscores are removed, and only as a whole cell, so "Group Category Name"
// is never read as the group column.

import Core
import Foundation

enum GroupRosterCSV {

    /// The students of the file, keyed by lowercased username, each with the
    /// group name the file gives. A row with a blank group puts its student in
    /// no group, so that student is absent here.
    struct Parsed: Equatable, Sendable {
        let groupByUsername: [String: String]
        /// Usernames in the order the file first lists them, for messages.
        let usernames: [String]
    }

    private static let usernameHeaders: [String] = ["username", "user", "userid", "login", "loginid"]
    private static let groupHeaders: [String] = ["groupname", "group", "labgroup", "lab", "sectionname", "section"]

    static func parse(_ data: Data) throws(CourseGroupError) -> Parsed {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw .unreadableFile
        }
        let rows =
            text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { DatasetMaterializer.splitCSVLine($0).map(clean) }
            .filter { row in row.contains { !$0.isEmpty } }
        guard let first = rows.first else { throw .emptyFile }

        let (usernameColumn, groupColumn, dataRows) = try columns(header: first, rows: rows)
        var groupByUsername: [String: String] = [:]
        var usernames: [String] = []
        var conflicts: [String] = []
        for row in dataRows {
            // A LEARN export writes `#username`; the enrol CSV reads it the same way.
            guard usernameColumn < row.count, let username = learnUsername(fromCell: row[usernameColumn]) else {
                continue
            }
            let key = username.lowercased()
            let group = groupColumn < row.count ? String(row[groupColumn].prefix(CourseGroupStore.nameLimit)) : ""
            if !usernames.contains(key) { usernames.append(key) }
            guard !group.isEmpty else { continue }
            if let earlier = groupByUsername[key] {
                if earlier.lowercased() != group.lowercased(), !conflicts.contains(key) { conflicts.append(key) }
            } else {
                groupByUsername[key] = group
            }
        }
        // Ten names are enough to find the rows; the rest only lengthen the message.
        guard conflicts.isEmpty else { throw .conflictingRows(usernames: Array(conflicts.prefix(10))) }
        guard !usernames.isEmpty else { throw .emptyFile }
        return Parsed(groupByUsername: groupByUsername, usernames: usernames)
    }

    /// The username and group columns, and the rows that hold data. A first
    /// row that names a username column is a header; any other first row is
    /// data in the two-column shape.
    private static func columns(
        header: [String], rows: [[String]]
    ) throws(CourseGroupError) -> (username: Int, group: Int, rows: ArraySlice<[String]>) {
        let names = header.map(headerKey)
        if let username = firstColumn(in: names, matching: usernameHeaders) {
            guard let group = firstColumn(in: names, matching: groupHeaders) else { throw .missingColumns }
            return (username, group, rows.dropFirst())
        }
        guard header.count >= 2 else { throw .missingColumns }
        return (0, 1, rows[...])
    }

    /// The column of the first keyword that names one, so "Username" wins over
    /// "User" and "Group Name" over "Group".
    private static func firstColumn(in names: [String], matching keywords: [String]) -> Int? {
        for keyword in keywords {
            if let index = names.firstIndex(of: keyword) { return index }
        }
        return nil
    }

    private static func headerKey(_ cell: String) -> String {
        cell.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
    }

    private static func clean(_ cell: String) -> String {
        cell.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
