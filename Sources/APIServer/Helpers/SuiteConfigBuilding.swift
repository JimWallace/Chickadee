// APIServer/Helpers/SuiteConfigBuilding.swift
//
// The suite-config decode/encode types (`ConfiguredSuiteEntry` and the
// editor's row shapes) and the builders that turn uploaded files into suite
// entries (`buildSuiteEntries`, `inferredOrder`, `normalizeTier`,
// `isLikelyTestSuiteScript`, `isLikelyTestSuiteFile`, `hasRecognizedScriptShebang`,
// `mergeExistingFilesIntoSuiteFiles`, `sanitizeSuiteFilename`). Moved from
// Routes/Web/SuiteRowHelpers.swift (#1726): the manifest builder and the
// publish step in Helpers/ use them, and Helpers/ must not call up into the
// routes.

import Core
import Foundation
import Vapor

// MARK: - Suite config decode/encode types

struct ReindexedSuiteConfigRow: Encodable {
    let index: Int
    let isTest: Bool
    let tier: String
    let order: Int?
    let dependsOn: [String]?  // script names of prerequisites
    let points: Int  // grade weight; 1 = default (unweighted)
    let displayName: String?  // optional human-readable name shown to students
}

struct SuiteConfigRow: Decodable {
    let index: Int
    let isTest: Bool?
    let tier: String?
    let order: Int?
    let dependsOn: [String]?  // script names of prerequisites
    let points: Int?  // grade weight; nil decoded as 1
    let displayName: String?  // optional human-readable name shown to students
}

struct ConfiguredSuiteEntry {
    let script: String
    let tier: String
    let order: Int
    let dependsOn: [String]  // script names of prerequisites; empty == none
    let points: Int  // grade weight; 1 = default (unweighted)
    let displayName: String?  // optional human-readable name shown to students
    let generatedBy: String?  // pattern family id; nil for hand-written scripts
    let generatedByCheck: String?  // notebook check id; nil otherwise
    let sectionID: String?  // id into TestProperties.sections; nil = ungrouped
    let hint: String?  // instructor hint for raw scripts; nil for generated/no-hint
    let timeLimitSeconds: Int?  // per-test override; nil = inherit assignment default
    let failureDetail: FailureDetail?  // student-facing failure detail; nil = full

    init(
        script: String, tier: String, order: Int,
        dependsOn: [String], points: Int, displayName: String?,
        generatedBy: String? = nil, generatedByCheck: String? = nil,
        sectionID: String? = nil, hint: String? = nil,
        timeLimitSeconds: Int? = nil,
        failureDetail: FailureDetail? = nil
    ) {
        self.script = script
        self.tier = tier
        self.order = order
        self.dependsOn = dependsOn
        self.points = points
        self.displayName = displayName
        self.generatedBy = generatedBy
        self.generatedByCheck = generatedByCheck
        self.sectionID = sectionID
        self.hint = hint
        self.timeLimitSeconds = timeLimitSeconds
        self.failureDetail = failureDetail
    }

    /// A manifest entry carried into a rebuild unchanged, apart from its
    /// position and (optionally) its prerequisites.
    init(_ entry: TestSuiteEntry, order: Int, dependsOn: [String]? = nil) {
        self.init(
            script: entry.script,
            tier: entry.tier.rawValue,
            order: order,
            dependsOn: dependsOn ?? entry.dependsOn,
            points: entry.points,
            displayName: entry.name,
            generatedBy: entry.generatedBy,
            generatedByCheck: entry.generatedByCheck,
            sectionID: entry.sectionID,
            hint: entry.hint,
            timeLimitSeconds: entry.timeLimitSeconds,
            failureDetail: entry.failureDetail
        )
    }
}

// MARK: - Suite-config building

/// Resolves config rows that reference files by name (source=="existing") so that
/// every row ends up with a numeric `index`.  The named files are extracted from
/// the draft ZIP and appended to `suiteFiles`; their config rows are rewritten to
/// use the new indices.  This lets `buildSuiteEntries` decode `SuiteConfigRow`
/// (which requires `index`) regardless of which sources are present.
func mergeExistingFilesIntoSuiteFiles(
    suiteFiles: [File],
    suiteConfigJSON: String?,
    draftZipPath: String?
) async -> ([File], String?) {
    guard let configJSON = suiteConfigJSON,
        let configData = configJSON.data(using: .utf8),
        var rows = (try? JSONSerialization.jsonObject(with: configData)) as? [[String: Any]]
    else {
        return (suiteFiles, suiteConfigJSON)
    }

    var mergedFiles = suiteFiles
    let uploadedNames = Set(suiteFiles.map { $0.filename })

    for i in rows.indices {
        var row = rows[i]
        guard let name = row["name"] as? String, row["index"] == nil else { continue }
        // Name-based row: find or extract the file, then rewrite row to use index.
        let fileIndex: Int
        if let existing = mergedFiles.firstIndex(where: { $0.filename == name }) {
            fileIndex = existing
        } else if let zipPath = draftZipPath,
            !uploadedNames.contains(name),
            let data = await extractZipEntry(zipPath: zipPath, entryName: name)
        {
            var buf = ByteBufferAllocator().buffer(capacity: data.count)
            buf.writeBytes(data)
            mergedFiles.append(File(data: buf, filename: name))
            fileIndex = mergedFiles.count - 1
        } else {
            continue
        }
        row["index"] = fileIndex
        row.removeValue(forKey: "name")
        row.removeValue(forKey: "source")
        rows[i] = row
    }

    guard let updatedData = try? JSONSerialization.data(withJSONObject: rows),
        let updatedJSON = String(data: updatedData, encoding: .utf8)
    else {
        return (mergedFiles, suiteConfigJSON)
    }
    return (mergedFiles, updatedJSON)
}

func sanitizeSuiteFilename(_ raw: String) -> String {
    var name = (raw as NSString).lastPathComponent
    if name.isEmpty { name = "suite-file" }
    name = name.replacingOccurrences(of: "/", with: "-")
    name = name.replacingOccurrences(of: "\\", with: "-")
    return name
}

func buildSuiteEntries(
    suiteFiles: [File],
    storedNameByIndex: [Int: String],
    suiteConfigJSON: String?
) throws -> [ConfiguredSuiteEntry] {
    let parsedRows: [SuiteConfigRow] = {
        guard let raw = suiteConfigJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let data = raw.data(using: .utf8),
            let rows = try? JSONDecoder().decode([SuiteConfigRow].self, from: data)
        else {
            return []
        }
        return rows
    }()

    if !parsedRows.isEmpty {
        var rowsByIndex: [Int: SuiteConfigRow] = [:]
        for row in parsedRows {
            rowsByIndex[row.index] = row
        }
        var selected: [ConfiguredSuiteEntry] = []
        for index in suiteFiles.indices {
            guard let row = rowsByIndex[index] else { continue }
            guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
            let tier = normalizeTier(row.tier, isTest: row.isTest)
            guard tier != "support" else { continue }
            selected.append(
                ConfiguredSuiteEntry(
                    script: script,
                    tier: tier,
                    order: row.order ?? (index + 1),
                    dependsOn: row.dependsOn ?? [],
                    points: row.points ?? 1,
                    displayName: row.displayName
                ))
        }
        return
            selected
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.script < rhs.script
            }
    }

    // Backward-compatible fallback when no suite config JSON is submitted.
    var defaults: [ConfiguredSuiteEntry] = []
    for index in suiteFiles.indices {
        guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
        guard isLikelyTestSuiteFile(suiteFiles[index], storedName: script) else { continue }
        defaults.append(
            ConfiguredSuiteEntry(
                script: script,
                tier: "public",
                order: inferredOrder(from: script) ?? (index + 1),
                dependsOn: [],
                points: 1,
                displayName: nil
            ))
    }
    return
        defaults
        .sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.script < rhs.script
        }
}

func inferredOrder(from filename: String) -> Int? {
    let base = (filename as NSString).lastPathComponent
    let ns = base as NSString
    let range = NSRange(location: 0, length: ns.length)
    let regex = try? NSRegularExpression(pattern: #"^([0-9]+)[_-].+$"#)
    guard let match = regex?.firstMatch(in: base, options: [], range: range),
        match.numberOfRanges >= 2,
        let orderRange = Range(match.range(at: 1), in: base)
    else {
        return nil
    }
    return Int(base[orderRange])
}

func normalizeTier(_ raw: String?, isTest: Bool? = nil) -> String {
    if isTest == false {
        return "support"
    }
    switch (raw ?? "public").lowercased() {
    case "support":
        return "support"
    case "secret": return "secret"
    case "release": return "release"
    case "public":
        return "public"
    default:
        return "public"
    }
}

/// Whether a suite upload named `name`, whose text starts with `leadingText`,
/// is a test script rather than a support file.
///
/// The one rule for both upload doors: the multipart create form
/// (`isLikelyTestSuiteFile`) and the suite table's JSON upload
/// (`createScriptInSetup`). The suite table used to decide in the browser from
/// its own extension list, which had gone stale and filed Lua, Octave, Racket
/// and Java tests as support files (#1960).
///
/// A file with an extension is a test when the runner can dispatch it, read
/// from RunnerCore's own table (`classifyScriptInterpreter`), so the answer
/// cannot drift from what actually runs. That table, not
/// `AssignmentLanguage.scriptExtensions`, is the right source: C++ claims
/// `cpp`, `h` and `hpp` there, but its tests are `.sh` wrappers and the runner
/// cannot run a `.cpp` file, so a C++ header is a support file. An
/// extensionless file is a test when its shebang names a shell, Python or Lua.
func isLikelyTestSuiteScript(name: String, leadingText: String) -> Bool {
    guard URL(fileURLWithPath: name).pathExtension.isEmpty else {
        return classifyScriptInterpreter(name: name, source: "") != .unknown
    }
    return hasRecognizedScriptShebang(leadingText)
}

func isLikelyTestSuiteFile(_ file: File, storedName: String) -> Bool {
    let head = Data(file.data.readableBytesView.prefix(256))
    return isLikelyTestSuiteScript(
        name: storedName, leadingText: String(bytes: head, encoding: .utf8) ?? "")
}

func hasRecognizedScriptShebang(_ text: String) -> Bool {
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.hasPrefix("#!") else { return false }
    if normalized.range(of: #"^#!\s*/.*/(ba|z)?sh\b"#, options: .regularExpression) != nil {
        return true
    }
    if normalized.range(of: #"^#!\s*/usr/bin/env\s+(ba|z)?sh\b"#, options: .regularExpression) != nil {
        return true
    }
    if normalized.range(of: #"^#!.*\bpython[0-9.]*\b"#, options: .regularExpression) != nil {
        return true
    }
    // `RunnerCore.classifyScriptInterpreter` already reads a `#!… lua` shebang
    // and dispatches it, so an extensionless Lua test runs perfectly well once
    // it is in the suite — this is only about letting it in.
    //
    // (Rscript is still absent here, matching `classifyScriptInterpreter`'s own
    // gap noted in docs/language-handling-review.md §4. Harmless while
    // instructors upload `.R` files, and out of scope for this change.)
    if normalized.range(of: #"^#!.*\blua[0-9.]*\b"#, options: .regularExpression) != nil {
        return true
    }
    return false
}
