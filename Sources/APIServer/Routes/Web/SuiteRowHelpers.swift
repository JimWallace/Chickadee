// APIServer/Routes/Web/SuiteRowHelpers.swift
//
// Suite-row decode/encode types, the row builders that feed
// the editor view (`editableSuiteRowsForSetup`, `familySuiteRowsForSetup`,
// `currentSetupFiles`), the publish-time authored-item reconstruction
// (`authoredSuiteItemsFromDraftManifest`), suite-config building
// (`buildSuiteEntries`, `inferredOrder`, `normalizeTier`,
// `isLikelyTestSuiteFile`, `hasRecognizedScriptShebang`,
// `mergeExistingFilesIntoSuiteFiles`, `sanitizeSuiteFilename`).
// Extracted from AssignmentHelpers.swift (issue #442) — no behaviour
// changes.

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

    init(
        script: String, tier: String, order: Int,
        dependsOn: [String], points: Int, displayName: String?,
        generatedBy: String? = nil, generatedByCheck: String? = nil,
        sectionID: String? = nil, hint: String? = nil,
        timeLimitSeconds: Int? = nil
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
    }
}

// MARK: - Editor view row builders

func currentSetupFiles(
    for setup: APITestSetup, assignmentID: String, solutionFilename: String?
) -> (
    assignmentFile: CurrentFileLink,
    solutionFile: CurrentFileLink?,
    existingSuiteRows: [EditableSuiteRow]
) {
    let assignmentFile: CurrentFileLink = {
        let fileName: String
        if let path = setup.notebookPath, !path.isEmpty {
            fileName = URL(fileURLWithPath: path).lastPathComponent
        } else {
            fileName = "assignment.ipynb"
        }
        return CurrentFileLink(
            name: fileName,
            url: "/instructor/\(assignmentID)/files/notebook"
        )
    }()

    struct ManifestSuiteRow {
        let script: String
        let tier: String
        let order: Int
        let dependsOn: [String]
        let points: Int
        let name: String?
        let isGenerated: Bool
    }

    let manifestSuites: [ManifestSuiteRow] = {
        guard let props = setup.decodedManifest()

        else {
            return []
        }
        return props.testSuites.enumerated().map { (idx, item) in
            ManifestSuiteRow(
                script: item.script, tier: item.tier.rawValue, order: idx + 1,
                dependsOn: item.dependsOn, points: item.points, name: item.name,
                isGenerated: item.isGenerated
            )
        }
    }()
    let testMap = Dictionary(uniqueKeysWithValues: manifestSuites.map { ($0.script, $0) })

    let archiveFiles = listZipEntries(zipPath: setup.zipPath)
    let solutionFile: CurrentFileLink? = {
        if let solutionEntry = archiveFiles.first(where: { $0.hasPrefix("solution.") }) {
            return CurrentFileLink(
                name: solutionEntry,
                url: "/instructor/\(assignmentID)/files/item?name=\(urlEncode(solutionEntry))"
            )
        }
        if let solutionFilename, !solutionFilename.isEmpty {
            return CurrentFileLink(name: solutionFilename, url: "/instructor/\(assignmentID)/files/solution")
        }
        return nil
    }()

    let nonNotebookFiles =
        archiveFiles
        .filter { $0 != "assignment.ipynb" && !$0.hasPrefix("solution.") }
        .sorted { lhs, rhs in
            let l = testMap[lhs]?.order ?? Int.max
            let r = testMap[rhs]?.order ?? Int.max
            if l != r { return l < r }
            return lhs < rhs
        }

    // Generated entries (pattern-family or notebook-check output) are
    // represented by their generator's row in the suite table, so omit
    // them from the raw script list here.
    let existingSuiteRows = nonNotebookFiles.enumerated().compactMap { idx, name -> EditableSuiteRow? in
        let entry = testMap[name]
        if entry?.isGenerated == true { return nil }
        return EditableSuiteRow(
            name: name,
            url: "/instructor/\(assignmentID)/files/item?name=\(urlEncode(name))",
            isTest: entry != nil,
            tier: entry?.tier ?? "support",
            order: entry?.order ?? (idx + 1),
            dependsOn: entry?.dependsOn ?? [],
            points: entry?.points ?? 1,
            displayName: entry?.name
        )
    }

    return (assignmentFile, solutionFile, existingSuiteRows)
}

func editableSuiteRowsForSetup(_ setup: APITestSetup) -> [EditableSuiteRow] {
    let entries = listZipEntries(zipPath: setup.zipPath)
        .filter { $0 != "assignment.ipynb" && $0 != "solution.ipynb" }
        .sorted()

    struct ManifestRow {
        let tier: String
        let order: Int
        let dependsOn: [String]
        let points: Int
        let name: String?
        let isGenerated: Bool
    }
    let manifestTests: [String: ManifestRow] = {
        guard let props = setup.decodedManifest()

        else {
            return [:]
        }
        var map: [String: ManifestRow] = [:]
        for (idx, entry) in props.testSuites.enumerated() {
            map[entry.script] = ManifestRow(
                tier: entry.tier.rawValue,
                order: idx + 1,
                dependsOn: entry.dependsOn,
                points: entry.points,
                name: entry.name,
                isGenerated: entry.isGenerated
            )
        }
        return map
    }()

    // Generated entries (pattern-family or notebook-check output) are
    // represented collectively by their family's / check's row in the
    // suite table — hide them from the raw list so instructors don't see
    // N duplicate generated rows.
    return entries.enumerated().compactMap { idx, name -> EditableSuiteRow? in
        let info = manifestTests[name]
        if info?.isGenerated == true { return nil }
        return EditableSuiteRow(
            name: name,
            url: "#",
            isTest: (info?.tier ?? "support") != "support",
            tier: info?.tier ?? "support",
            order: info?.order ?? (idx + 1),
            dependsOn: info?.dependsOn ?? [],
            points: info?.points ?? 1,
            displayName: info?.name
        )
    }
    .sorted { lhs, rhs in
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.name < rhs.name
    }
}

/// Builds an `[AuthoredSuiteItem]` list from a draft test setup's manifest,
/// reconciling it with the raw-script list that `createRunnerSetupZip` just
/// produced for publish.  Walks the draft's `testSuites` in order, emitting
/// a `.script` for each non-generated entry that still exists in the new zip
/// (carrying the newly-computed tier/points/dependsOn) and a `.family`
/// marker at the position of each family's first generated entry.  Any raw
/// scripts present in the new zip but absent from the draft manifest (e.g.
/// fresh form uploads) are appended at the end.
///
/// Used by `saveNewAssignment` so the publish-time re-apply of pattern
/// families preserves each family's draft position instead of dumping every
/// family at the end of the suite.
func authoredSuiteItemsFromDraftManifest(
    draftProps: TestProperties?,
    newRawEntries: [ConfiguredSuiteEntry]
) -> [AuthoredSuiteItem] {
    guard let draftProps else {
        return newRawEntries.map {
            .script(
                AuthoredRawScript(
                    script: $0.script,
                    tier: TestTier(rawValue: $0.tier) ?? .pub,
                    points: $0.points,
                    displayName: $0.displayName,
                    dependsOn: $0.dependsOn,
                    sectionID: $0.sectionID
                ))
        }
    }
    let newByScript: [String: ConfiguredSuiteEntry] = Dictionary(
        uniqueKeysWithValues: newRawEntries.map { ($0.script, $0) }
    )
    var items: [AuthoredSuiteItem] = []
    var seenFamilies: Set<String> = []
    var seenChecks: Set<String> = []
    var seenScripts: Set<String> = []
    for entry in draftProps.testSuites {
        if let fid = entry.generatedBy {
            guard !seenFamilies.contains(fid) else { continue }
            seenFamilies.insert(fid)
            // v0.4.134: propagate sectionID from the draft's family-generated
            // entry so families published from the create page keep their
            // section assignment instead of falling into Ungrouped.
            items.append(.family(id: fid, sectionID: entry.sectionID))
        } else if let cid = entry.generatedByCheck {
            // v0.4.134: same fix for notebook checks — without this the
            // check-generated entries fall through to applyPatternFamilies'
            // "checks not in authoredItems" branch which appends them at
            // the end with `sectionID: nil`.
            guard !seenChecks.contains(cid) else { continue }
            seenChecks.insert(cid)
            items.append(.check(id: cid, sectionID: entry.sectionID))
        } else {
            guard let newEntry = newByScript[entry.script] else { continue }
            seenScripts.insert(entry.script)
            items.append(
                .script(
                    AuthoredRawScript(
                        script: newEntry.script,
                        tier: TestTier(rawValue: newEntry.tier) ?? .pub,
                        points: newEntry.points,
                        displayName: newEntry.displayName,
                        dependsOn: newEntry.dependsOn,
                        // v0.4.134: prefer the draft's sectionID over the rebuilt
                        // raw entry's (which loses sectionID through the JSON
                        // round-trip via ReindexedSuiteConfigRow).
                        sectionID: entry.sectionID ?? newEntry.sectionID
                    )))
        }
    }
    for newEntry in newRawEntries where !seenScripts.contains(newEntry.script) {
        items.append(
            .script(
                AuthoredRawScript(
                    script: newEntry.script,
                    tier: TestTier(rawValue: newEntry.tier) ?? .pub,
                    points: newEntry.points,
                    displayName: newEntry.displayName,
                    dependsOn: newEntry.dependsOn,
                    sectionID: newEntry.sectionID
                )))
    }
    return items
}

/// Returns one `FamilySuiteRow` per pattern family declared on this setup.
/// Used to populate the family rows in the assignment editor's suite table.
func familySuiteRowsForSetup(_ setup: APITestSetup) -> [FamilySuiteRow] {
    guard let props = setup.decodedManifest()

    else { return [] }
    return props.patternFamilies.map { family in
        let totalPoints = family.cases
            .filter(\.enabled)
            .map { $0.resolvedPoints(defaults: family.defaults) }
            .reduce(0, +)
        return FamilySuiteRow(
            id: family.id,
            name: family.name,
            functionName: family.functionName,
            tier: family.defaults.tier.rawValue,
            caseCount: family.cases.filter(\.enabled).count,
            totalPoints: totalPoints
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
) -> ([File], String?) {
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
            let data = extractZipEntry(zipPath: zipPath, entryName: name)
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

func isLikelyTestSuiteFile(_ file: File, storedName: String) -> Bool {
    // Every assignment language's extension, from the one table, UNION the
    // script languages the runner can dispatch that no assignment is authored
    // in. The assignment half used to be hand-listed as `py` / `r`, so a `.lua`
    // suite file uploaded through the web form was silently skipped — not
    // rejected with a message, just dropped from the suite — while the MCP
    // `author_script` path accepted it. A new language joins this the day its
    // case exists.
    let nonAssignmentScriptExtensions: Set<String> = ["sh", "bash", "zsh", "rb", "pl", "js", "php"]
    let assignmentExtensions = Set(AssignmentLanguage.allCases.flatMap(\.scriptExtensions))
    let ext = URL(fileURLWithPath: storedName).pathExtension.lowercased()
    if assignmentExtensions.contains(ext) || nonAssignmentScriptExtensions.contains(ext) {
        return true
    }
    guard ext.isEmpty else { return false }
    return hasRecognizedScriptShebang(file)
}

func hasRecognizedScriptShebang(_ file: File) -> Bool {
    let head = Data(file.data.readableBytesView.prefix(256))
    guard let prefix = String(bytes: head, encoding: .utf8) else { return false }
    let firstLine = prefix.split(whereSeparator: \.isNewline).first.map(String.init) ?? prefix
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
