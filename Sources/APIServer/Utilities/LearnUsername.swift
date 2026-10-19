// APIServer/Utilities/LearnUsername.swift
//
// Reads a username out of one cell of a LEARN (Brightspace) export. The enrol
// CSV (`parseUsernamesFromCSV`) and the group import (`GroupRosterCSV`,
// docs/lab-groups.md) both call it, so they read a LEARN export alike.

/// The username in one trimmed cell, or nil when the cell names no real student.
func learnUsername(fromCell raw: String) -> String? {
    // Brightspace's "End-of-Line Indicator" column is literally `#` —
    // when the chosen column lands on that, drop it.  Bare `#` is
    // never a real username.
    guard !raw.isEmpty, raw != "#" else { return nil }
    // Drop Brightspace gradebook-test-account rows entirely — they
    // shouldn't pollute a real class roster (v0.4.128).
    if isBrightspaceTestAccount(raw) { return nil }
    let stripped = stripBrightspacePrefix(raw)
    return stripped.isEmpty ? nil : stripped
}

// Strip the Brightspace `#` prefix that's prepended to every
// OrgDefinedId / Username cell so spreadsheet tools don't
// auto-convert numeric quest IDs to numbers.  The real-world shape
// for an actual student in a UWaterloo Brightspace export is bare
// `#<questname>` (e.g. `#mj39lee`); the dotted form
// `#<digits>.<rest>` (e.g. `#174667.teststudent1`) is reserved for
// gradebook test accounts and is filtered out by the parse loop
// before this function runs (see `isBrightspaceTestAccount`).
//
// Pre-v0.4.128 only the dotted form was stripped, so the bulk-
// enroll path accepted test accounts but rejected every real
// student in the class (their `#mj39lee`-style values fell through
// and were rejected for containing `#`).
private func stripBrightspacePrefix(_ s: String) -> String {
    guard s.hasPrefix("#"), s.count > 1 else { return s }
    return String(s.dropFirst())
}

// Detects Brightspace gradebook-test-account rows: the namespaced
// `#<digits>.<rest>` shape that Brightspace uses for institution-
// issued test users (e.g. `#174667.teststudent1`).  These should
// not pollute a real class roster — instructors who upload a
// gradebook export expect only the actual class members to enrol.
//
// Real students have a bare `#<questname>` shape with no
// intervening dot, which falls through this predicate and goes
// through normal stripping.
private func isBrightspaceTestAccount(_ s: String) -> Bool {
    guard s.hasPrefix("#") else { return false }
    let afterHash = s.dropFirst()
    guard let dotIdx = afterHash.firstIndex(of: ".") else { return false }
    let prefix = afterHash[..<dotIdx]
    return !prefix.isEmpty && prefix.allSatisfy(\.isNumber)
}
