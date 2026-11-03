// APIServer/Utilities/CourseCodeSyntax.swift
//
// The characters a course code may not use, because a link cannot carry them.
// A course link is `/<urlKey>/<slug>`, and nothing encodes the key when it
// writes the link. Vapor splits the request path on "/" while it is still
// percent-encoded, and RoutingKit then decodes each parameter
// (`Parameters.set`). So:
//
// - a space or a non-ASCII letter works: the browser encodes it and the
//   router decodes it;
// - "/" splits the key into two segments, and a browser turns "\" into "/";
// - "?" and "#" end the path, so the rest of the link is a query or fragment;
// - "%" is read as the start of an escape;
// - a code that is "." or ".." is removed from the path by the browser;
// - a control character cannot be typed into a link at all.
//
// Every link to such a course is a 404 or the wrong page.

/// The syntax rule for a course code.
enum CourseCodeSyntax {
    /// The characters a link cannot carry unencoded in a path segment.
    static let refusedCharacters: Set<Character> = ["/", "\\", "?", "#", "%"]

    /// True when a link can carry `code` as its first path segment: the code
    /// is not empty, not "." or "..", and has no refused or control character.
    static func isURLSafe(_ code: String) -> Bool {
        guard !code.isEmpty, code != ".", code != ".." else { return false }
        return !code.contains { character in
            refusedCharacters.contains(character)
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    /// The words every door shows for a code that fails the rule.
    static let message =
        "A course code cannot contain the characters / \\ ? # or %, and cannot be . or .. alone. Links to the course cannot carry them."
}
