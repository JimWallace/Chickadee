// APIServer/GitHub/GitHubRepositoryName.swift
//
// A GitHub repository as `owner/name`, checked before it goes into a
// github.com URL. An instructor may paste the name or the repository's URL.
// The owner follows the login rules of `GitHubOrganizationName`; a name is 1
// to 100 letters, digits, `.`, `-` and `_`, and is not `.` or `..`.

import Foundation

struct GitHubRepositoryName: Sendable, Equatable {
    /// `owner/name`.
    let value: String

    /// The repository's page on GitHub.
    var url: String { "https://github.com/\(GitHubRepoClient.repoPath(value))" }

    /// Nil for text that is not `owner/name` or a github.com repository URL.
    /// Surrounding whitespace, a trailing `/` and a trailing `.git` are ignored.
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let owner = GitHubOrganizationName(parts[0]) else { return nil }
        let name = parts[1]
        guard
            (1...100).contains(name.count), name != ".", name != "..",
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
        else { return nil }
        value = "\(owner.value)/\(name)"
    }
}
