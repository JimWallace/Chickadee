// Core/FilenameSafety.swift
//
// Shared bare-filename validation (#1104). Instructor-authored file names
// (dataset specs, personalized-file keys) cross a trust boundary: the server
// and the worker both join them onto directory paths before reading or
// writing, so a name carrying a separator or a traversal component would
// escape the intended directory. Every consumer of such a name validates it
// through this one helper so the rule can't drift between the route
// validator, the server-side resolver/writer, and the worker's writer.

import Foundation

public enum FilenameSafety {

    /// Returns `raw` when it is a bare filename — a single path component
    /// with no separators and no `.`/`..` traversal — and nil otherwise.
    /// The name is returned unchanged (never rewritten), so a nil result is
    /// the only signal a caller needs to reject the value.
    public static func bareFilename(_ raw: String) -> String? {
        let cleaned = (raw as NSString).lastPathComponent
        guard cleaned == raw, !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }
}
