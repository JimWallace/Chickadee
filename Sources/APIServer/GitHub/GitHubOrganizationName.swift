// APIServer/GitHub/GitHubOrganizationName.swift
//
// A GitHub organization login, checked before it goes into a github.com URL
// path. GitHub allows 1 to 39 characters: letters, digits and single hyphens,
// with no hyphen at either end.

import Foundation

struct GitHubOrganizationName: Sendable, Equatable {
    let value: String

    /// Nil for text that is not a valid organization login. Surrounding
    /// whitespace is ignored.
    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            (1...39).contains(text.count),
            text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
            !text.hasPrefix("-"), !text.hasSuffix("-"), !text.contains("--")
        else { return nil }
        value = text
    }
}
