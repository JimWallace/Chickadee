// Core/SuiteEntryOrigin.swift
//
// Where a `TestSuiteEntry` came from.  The manifest stores this as two
// optionals (`generatedBy`, `generatedByCheck`), and validation keeps at most
// one of them set.  This enum states the three real states so a call site
// can switch over them, and the compiler checks that it handles each one.
// See docs/manifest-format-v2.md, D4.

/// The author of a suite entry's script.
public enum SuiteEntryOrigin: Equatable, Sendable {
    /// The instructor wrote the script.
    case handWritten
    /// A pattern family generated the script.  The value is the family id.
    case family(id: String)
    /// A notebook check generated the script.  The value is the check id.
    case check(id: String)
}

extension TestSuiteEntry {
    /// The origin of this entry's script.
    ///
    /// When a manifest that did not pass validation sets both fields, the
    /// family wins.  Every call site that tested the two fields in turn
    /// tested `generatedBy` first, so this keeps their behaviour.
    public var origin: SuiteEntryOrigin {
        if let generatedBy { return .family(id: generatedBy) }
        if let generatedByCheck { return .check(id: generatedByCheck) }
        return .handWritten
    }
}
