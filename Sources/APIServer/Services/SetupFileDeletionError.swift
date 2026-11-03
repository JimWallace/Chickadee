// APIServer/Services/SetupFileDeletionError.swift
//
// Why `deleteFileFromSetup` refused to remove a file from a test setup. The
// web `DELETE /scripts/:filename` routes and MCP `delete_support_file` each
// word the refusal for their own caller, so this carries the facts, not the
// prose (#2771).

enum SetupFileDeletionError: Error, Sendable, Equatable {
    /// The setup zip has no entry of this name.
    case notInSetup(String)
    /// A pattern family generates the file. Its family owns it.
    case generatedByFamily(file: String, familyID: String)
    /// The file is attached from the course library
    /// (`libraryAttachmentRefusal`), with the reason that check gave.
    case libraryAttached(String)
    /// Suite entries name the file in their `dependsOn`.
    case hasDependents(file: String, dependents: [String])
    /// The setup zip could not be rewritten.
    case zipUpdateFailed
}
