// APIServer/Utilities/DeployReleaseNotes.swift
//
// The held release's notes, split into the entries the admin Deployment page
// lists, with each contract change flagged (docs/release-gate.md).

import Foundation

/// Release notes split into the entries the admin page lists.
enum DeployReleaseNotes {
    struct Entry: Sendable, Equatable {
        /// The entry's text with its list marker and bold markers removed.
        let text: String
        /// A `### Changed`-style heading rather than a bullet.
        let isHeading: Bool
        /// The entry names a pull request that carried the `minor-release`
        /// label: a contract change.
        let isContractChange: Bool
    }

    /// Splits a release body (a CHANGELOG section) into its headings and
    /// bullets. A bullet's indented continuation lines join it. An entry is
    /// flagged when it names one of `contractPullRequests` as `#N`.
    static func entries(in body: String, contractPullRequests: Set<Int>) -> [Entry] {
        var entries: [Entry] = []
        var current: String?

        func finish() {
            guard let text = current else { return }
            current = nil
            let cleaned = text.replacingOccurrences(of: "**", with: "")
            entries.append(
                Entry(
                    text: cleaned, isHeading: false,
                    isContractChange: !referencedNumbers(in: cleaned).isDisjoint(with: contractPullRequests)))
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                finish()
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    entries.append(Entry(text: heading, isHeading: true, isContractChange: false))
                }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                finish()
                current = String(line.dropFirst(2))
            } else if line.isEmpty {
                finish()
            } else if let text = current {
                current = text + " " + line
            } else {
                current = line
            }
        }
        finish()
        return entries
    }

    /// Every `#N` in `text`.
    static func referencedNumbers(in text: String) -> Set<Int> {
        Set(text.matches(of: pullRequestReference).compactMap { Int($0.output.1) })
    }

    private static var pullRequestReference: Regex<(Substring, Substring)> { /#([0-9]+)/ }
}
