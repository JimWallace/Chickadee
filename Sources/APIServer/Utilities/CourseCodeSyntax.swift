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
// The links Chickadee writes encode the key (`VanityURLRoutes.vanityPath`), so
// they work. A link typed by hand, or pasted into an LMS from the bare code, is
// not encoded, and it is a 404 or the wrong page.

/// The syntax rule for a course code.
enum CourseCodeSyntax {
    /// The characters that change how a link is read: they split the path,
    /// end it, or start an escape. A browser encodes a space, so it is not one.
    static let refusedCharacters: Set<Character> = ["/", "\\", "?", "#", "%"]

    /// True when a link can carry `code` as its first path segment: the code
    /// is not empty, not "." or "..", and has no refused or control character.
    /// (A termed course's key adds "-F26", so only the bare code can be "..".)
    static func isURLSafe(_ code: String) -> Bool {
        guard !code.isEmpty, code != ".", code != ".." else { return false }
        return !code.contains { character in
            refusedCharacters.contains(character)
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }

    /// The words every door shows for a code that fails the rule.
    static let message =
        "A course code cannot contain / \\ ? # or %, and cannot be \".\" or \"..\"."
}
