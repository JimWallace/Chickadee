// APIServer/Utilities/AuthoringChecks/MissingDataFileCheck.swift
//
// Reports a data file that the starter notebook's code names but that students
// do not receive (#2747). What a student receives is `StudentWorkspaceFiles`,
// the rule the working-copy pass uses. A quoted string in a code cell that ends
// in a data-file extension is read as a file the notebook opens.
//
// This is a scan of literals, not of the language's file calls, so it narrows
// the obvious false positives and stays a `warning`:
// - text after `#` or `//` on a line is a comment and is skipped;
// - a name on a line that writes (`to_csv`, `write`, `save`, `dump`, an
//   `open` in mode w or a) is a file the notebook makes, and is never reported,
//   from that cell or any other.

import Core

struct MissingDataFileCheck: AuthoringCheck {
    static let id = "files.missing"
    static let severity = AuthoringFinding.Severity.warning

    /// A quoted relative path ending in a data-file extension. `Regex` is not
    /// `Sendable`, so this is computed.
    static var dataFileLiteral: Regex<(Substring, Substring)> {
        /["']([A-Za-z0-9_.\/-]+\.(?:csv|tsv|txt|json|xlsx|xls|parquet|dat|rds|rdata|mat|xml))["']/
            .ignoresCase()
    }

    /// A line that writes a file, in any of the editor languages.
    static var writeCall: Regex<Substring> {
        /to_csv|to_json|to_excel|to_parquet|write|save|dump|["'][wa]b?["']/.ignoresCase()
    }

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        guard let zipEntries = snapshot.setupZipEntries else { return [] }
        let manifest = snapshot.manifest
        let delivered = StudentWorkspaceFiles.delivered(zipEntries: zipEntries, manifest: manifest)
        let graderOnly = manifest.graderOnlyFileSet

        var read: [(cell: Int, path: String)] = []
        var written = Set<String>()
        // Built once per check, not once per line: each read of the computed
        // properties builds and compiles the pattern again.
        let writeCall = Self.writeCall
        let dataFileLiteral = Self.dataFileLiteral
        for (index, cell) in snapshot.notebookCodeCells.enumerated() {
            guard let source = cell else { continue }
            for line in source.split(whereSeparator: \.isNewline) {
                let code = Self.withoutComment(String(line))
                let writes = code.contains(writeCall)
                for match in code.matches(of: dataFileLiteral) {
                    let named = String(match.output.1)
                    let path = named.hasPrefix("./") ? String(named.dropFirst(2)) : named
                    guard !path.hasPrefix("/") else { continue }
                    if writes { written.insert(path) } else { read.append((index, path)) }
                }
            }
        }

        var seen = Set<String>()
        return read.compactMap { cell, path in
            guard !delivered.contains(path), !written.contains(path), seen.insert(path).inserted else { return nil }
            let reason =
                graderOnly.contains(path)
                ? "is grader-only, so students do not receive it"
                : "is not a support file or an attached dataset"
            return finding(
                at: .notebookCell(cell),
                "The starter notebook opens \(path), which \(reason). A student's code that opens it fails.",
                fix: "Add \(path) as a support file or attach the dataset, or correct the name.")
        }
    }

    /// `line` up to its first `#` or `//`. A marker inside a string is cut
    /// too, which can only hide a literal, never invent one.
    static func withoutComment(_ line: String) -> String {
        let hash = line.firstIndex(of: "#") ?? line.endIndex
        let slashes = line.firstRange(of: "//")?.lowerBound ?? line.endIndex
        return String(line[..<min(hash, slashes)])
    }
}
