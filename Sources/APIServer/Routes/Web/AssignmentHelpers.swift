// APIServer/Routes/Web/AssignmentHelpers.swift
//
// Private free functions and helper types for assignment management routes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation
import Crypto

// MARK: - Helper-internal types

struct EditSuiteConfigRow: Decodable {
    let source: String?
    let name: String?
    let displayName: String?   // optional human-readable name shown to students
    let index: Int?
    let isIncluded: Bool?
    let isTest: Bool?
    let tier: String?
    let order: Int?
    let dependsOn: [String]?   // script names of prerequisites
    let points: Int?           // grade weight; nil decoded as 1
}

struct ReindexedSuiteConfigRow: Encodable {
    let index: Int
    let isTest: Bool
    let tier: String
    let order: Int?
    let dependsOn: [String]?   // script names of prerequisites
    let points: Int            // grade weight; 1 = default (unweighted)
    let displayName: String?   // optional human-readable name shown to students
}

struct ResolvedEditSuiteFiles {
    let files: [File]
    let reindexedSuiteConfigJSON: String?
}

struct SuiteConfigRow: Decodable {
    let index: Int
    let isTest: Bool?
    let tier: String?
    let order: Int?
    let dependsOn: [String]?   // script names of prerequisites
    let points: Int?           // grade weight; nil decoded as 1
    let displayName: String?   // optional human-readable name shown to students
}

struct ConfiguredSuiteEntry {
    let script: String
    let tier: String
    let order: Int
    let dependsOn: [String]    // script names of prerequisites; empty == none
    let points: Int            // grade weight; 1 = default (unweighted)
    let displayName: String?   // optional human-readable name shown to students
    let generatedBy: String?   // pattern family id; nil for hand-written scripts
    let generatedByCheck: String? // notebook check id; nil otherwise
    let sectionID: String?     // id into TestProperties.sections; nil = ungrouped

    init(script: String, tier: String, order: Int,
         dependsOn: [String], points: Int, displayName: String?,
         generatedBy: String? = nil, generatedByCheck: String? = nil,
         sectionID: String? = nil) {
        self.script = script
        self.tier = tier
        self.order = order
        self.dependsOn = dependsOn
        self.points = points
        self.displayName = displayName
        self.generatedBy = generatedBy
        self.generatedByCheck = generatedByCheck
        self.sectionID = sectionID
    }
}

struct RunnerSetupPackage {
    let testSuites: [ConfiguredSuiteEntry]
    let hasMakefile: Bool
}

enum RunnerValidationOutcome {
    case passed(summary: String)
    case failed(summary: String)
    case timedOut
}

func minimalEmptyNotebookData() -> Data {
    Data(#"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)
}

// MARK: - Free functions

/// Validates a sectionID string (UUID) against the given course and returns the UUID if valid.
/// Returns nil for absent, empty, or "none" values (meaning "ungrouped").
func resolveSectionID(_ raw: String?, courseID: UUID, db: Database) async throws -> UUID? {
    guard let raw, !raw.isEmpty, raw.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "Invalid sectionID format.")
    }
    guard let section = try await APICourseSection.find(uuid, on: db),
          section.courseID == courseID else {
        // Section not found or belongs to a different course — silently ignore.
        return nil
    }
    return uuid
}

func parseDueDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: raw) { return d }

    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.date(from: raw)
}

func waterlooDateTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_CA")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt
}

func splitHumanName(_ raw: String?) -> (surname: String, givenNames: String)? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(",") {
        let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let surname = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let givenNames = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (
            surname.isEmpty ? "—" : surname,
            givenNames.isEmpty ? "—" : givenNames
        )
    }

    let parts = trimmed.split(whereSeparator: \.isWhitespace)
    guard !parts.isEmpty else { return nil }
    if parts.count == 1 {
        return ("—", String(parts[0]))
    }

    let surname = String(parts.last ?? "")
    let givenNames = parts.dropLast().joined(separator: " ")
    return (
        surname.isEmpty ? "—" : surname,
        givenNames.isEmpty ? "—" : givenNames
    )
}

func assignmentByPublicID(_ publicID: String, on db: Database) async throws -> APIAssignment? {
    try await APIAssignment.query(on: db)
        .filter(\.$publicID == publicID)
        .first()
}

func uniqueAssignmentSlug(
    title: String,
    courseID: UUID,
    excludingAssignmentID: UUID? = nil,
    db: Database,
    reserved: Set<String> = []
) async throws -> String {
    let base = VanityURLRoutes.slugify(title).isEmpty ? "assignment" : VanityURLRoutes.slugify(title)
    for suffix in 0..<10_000 {
        let candidate = suffix == 0 ? base : "\(base)-\(suffix + 1)"
        if reserved.contains(candidate) { continue }

        var query = APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .filter(\.$slug == candidate)
        if let excludingAssignmentID {
            query = query.filter(\.$id != excludingAssignmentID)
        }
        let exists = try await query.count() > 0
        if !exists { return candidate }
    }
    throw Abort(.internalServerError, reason: "Unable to allocate assignment URL slug")
}

func isValidAssignmentPublicID(_ value: String) -> Bool {
    value.count == APIAssignment.publicIDLength
        && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

func assignmentPublicIDParameter(from req: Request) throws -> String {
    guard let raw = req.parameters.get("assignmentID"), isValidAssignmentPublicID(raw) else {
        throw Abort(.notFound)
    }
    return raw
}

func createAssignmentWithUniquePublicID(
    req: Request,
    testSetupID: String,
    title: String,
    dueAt: Date?,
    isOpen: Bool,
    sortOrder: Int?,
    validationStatus: String? = nil,
    validationSubmissionID: String? = nil,
    sectionID: UUID? = nil,
    courseID: UUID
) async throws -> APIAssignment {
    for _ in 0..<32 {
        let candidate = APIAssignment.generatePublicID()
        let exists = try await APIAssignment.query(on: req.db)
            .filter(\.$publicID == candidate)
            .count() > 0
        if exists { continue }

        let assignment = APIAssignment(
            publicID: candidate,
            testSetupID: testSetupID,
            title: title,
            slug: try await uniqueAssignmentSlug(title: title, courseID: courseID, db: req.db),
            dueAt: dueAt,
            isOpen: isOpen,
            sortOrder: sortOrder,
            validationStatus: validationStatus,
            validationSubmissionID: validationSubmissionID,
            sectionID: sectionID,
            courseID: courseID
        )
        do {
            try await assignment.save(on: req.db)
        } catch {
            let conflict = try await APIAssignment.query(on: req.db)
                .filter(\.$publicID == candidate)
                .count() > 0
            if conflict { continue }
            throw error
        }
        return assignment
    }

    throw Abort(.internalServerError, reason: "Unable to allocate assignment URL id")
}

func sanitizedAssignmentReturnPath(
    _ raw: String?,
    assignmentIDRaw: String,
    fallbackPath: String
) -> String {
    guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else {
        return fallbackPath
    }

    let expectedPrefix = "/instructor/\(assignmentIDRaw)"
    guard path == expectedPrefix || path.hasPrefix(expectedPrefix + "/") else {
        return fallbackPath
    }
    return path
}

func dueAtLocalInputString(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.string(from: date)
}

func deadlineOverrideValueForInstructorOpen(
    dueAt: Date?,
    now: Date = Date()
) -> Bool {
    guard let dueAt else { return false }
    return dueAt <= now
}

func normalizedDeadlineOverrideAfterDueDateChange(
    dueAt: Date?,
    existingOverride: Bool
) -> Bool {
    guard let dueAt else { return false }
    return dueAt <= Date() ? existingOverride : false
}

func notebookFilenameForStorage(uploadedName: String?, fallback: String) -> String {
    var fileName = uploadedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if fileName.isEmpty {
        fileName = fallback
    }
    fileName = URL(fileURLWithPath: fileName).lastPathComponent
    fileName = fileName
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
        fileName = fallback
    }
    if !fileName.lowercased().hasSuffix(".ipynb") {
        fileName += ".ipynb"
    }
    return fileName
}

func submissionFilenameForStorage(uploadedName: String?, fallback: String) -> String {
    var fileName = uploadedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if fileName.isEmpty {
        fileName = fallback
    }
    fileName = URL(fileURLWithPath: fileName).lastPathComponent
    fileName = fileName
        .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r"))
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
        fileName = fallback
    }
    return fileName
}

func currentSetupFiles(for setup: APITestSetup, assignmentID: String, solutionFilename: String?) -> (
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

    let manifestSuites: [(script: String, tier: String, order: Int, dependsOn: [String], points: Int, name: String?, isGenerated: Bool)] = {
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
            return []
        }
        return props.testSuites.enumerated().map { (idx, item) in
            (script: item.script, tier: item.tier.rawValue, order: idx + 1,
             dependsOn: item.dependsOn, points: item.points, name: item.name,
             isGenerated: item.isGenerated)
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

    let nonNotebookFiles = archiveFiles
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

func listZipEntries(zipPath: String) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", zipPath]

    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return [] }
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text
        .split(separator: "\n")
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
        .filter { !$0.isEmpty && !$0.hasSuffix("/") }
}

// MARK: - Script zip read/write helpers

enum ScriptZipError: Error {
    case fileNotFound(String)
    case invalidUTF8
    case zipFailed
}

/// Reads a single file from a test setup zip and returns it as a UTF-8 string.
/// Returns `nil` if the entry does not exist.
func readScriptFromZip(zipPath: String, filename: String) -> String? {
    guard let data = extractZipEntry(zipPath: zipPath, entryName: filename) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Replaces or adds a file in the test setup zip with new UTF-8 text content.
///
/// Strategy: extract all entries to a temp directory, overwrite/add the target
/// file, delete the original zip, then re-create it from the temp directory.
func updateScriptInZip(zipPath: String, filename: String, content: String) throws {
    guard let contentData = content.data(using: .utf8) else {
        throw ScriptZipError.invalidUTF8
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_edit_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Extract all current entries.
    for entry in listZipEntries(zipPath: zipPath) {
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    // Write the new/updated file.
    let fileURL = tempDir.appendingPathComponent(filename)
    try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contentData.write(to: fileURL)

    // Remove old zip and re-create from temp directory.
    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

/// Applies a batch of script writes and deletions to a test setup zip in a
/// single extract-then-repack cycle.  Cheaper than repeated single-file
/// updates when regenerating a whole pattern family at once.
///
/// - `writes`: filename → UTF-8 content.  Overwrites if the entry exists.
/// - `deletions`: filenames to remove.  Missing entries are silently ignored.
///   Applied before writes, so the same filename in both collections results
///   in the `writes` value winning.
/// Runs a section-aware scan over `notebookData` and, if the test setup
/// looks "fresh" (no existing sections, no existing test scripts), writes
/// one `publictest_exists_<fn>.py` scaffold per detected function into
/// the zip and updates the manifest to declare the sections + entries.
///
/// Silently no-ops if the setup already has sections or test entries —
/// instructors who've manually arranged things shouldn't get clobbered
/// by a re-upload of the solution notebook.  One-shot behaviour only.
/// v0.4.100+.
@discardableResult
func autoScaffoldFromSolutionNotebook(
    setup: APITestSetup,
    notebookData: Data,
    zipPath: String,
    on db: Database
) async throws -> (sections: Int, functions: Int) {
    // Parse the existing manifest so we know whether to scaffold.
    guard let data = setup.manifest.data(using: .utf8),
          var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return (0, 0)
    }
    let existingSections = (dict["sections"] as? [[String: Any]]) ?? []
    let existingSuites = (dict["testSuites"] as? [[String: Any]]) ?? []
    guard existingSections.isEmpty && existingSuites.isEmpty else {
        // Manifest already has structure — the instructor is on a
        // subsequent upload or has manually curated things.  Leave it
        // alone per the v0.4.100 scope ("create flow only, one-shot").
        return (0, 0)
    }

    let scan = scanNotebookForSectionsAndFunctions(notebookData)
    // Nothing useful to scaffold if no functions were found.  Still add
    // the sections (they're cheap) so the instructor can drop their own
    // scripts in.  But with zero functions there's also little value —
    // bail out to keep the manifest minimal.
    guard !scan.functions.isEmpty else { return (0, 0) }

    // 1. Assign a stable UUID per section (server-generated; clients
    //    get it back via GET /suite).
    var sectionIDByName: [String: String] = [:]
    var sectionDicts: [[String: Any]] = []
    for name in scan.sectionNames {
        let id = UUID().uuidString
        sectionIDByName[name] = id
        sectionDicts.append(["id": id, "name": name])
    }

    // 2. Generate one "exists" test script per detected function.
    //    Skip shadowed redefinitions — Python's last-def-wins semantics
    //    means the earlier function isn't reachable at test time.
    var writes: [String: String] = [:]
    var newSuites: [[String: Any]] = []
    for entry in scan.functions where !entry.info.isShadowed {
        let fn = entry.info.name
        let filename = "publictest_exists_\(fn).py"
        guard writes[filename] == nil else { continue }  // dedup by filename
        writes[filename] = pythonTestScript(type: .exists, functionName: fn)
        var testDict: [String: Any] = [
            "tier":   "public",
            "script": filename,
            "name":   "\(fn) exists",
        ]
        if let sectionName = entry.sectionName, let sid = sectionIDByName[sectionName] {
            testDict["sectionID"] = sid
        }
        newSuites.append(testDict)
    }
    guard !writes.isEmpty else { return (scan.sectionNames.count, 0) }

    // 3. Write the scaffold files into the zip (idempotent — if the file
    //    somehow already exists, the same content overwrites).
    try applyScriptChangesToZip(zipPath: zipPath, writes: writes, deletions: [])

    // 4. Rewrite the manifest with sections + testSuites populated.
    //    Preserve every other field the manifest already had (gradingMode,
    //    timeLimitSeconds, etc.).
    dict["sections"] = sectionDicts
    dict["testSuites"] = newSuites
    let newData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    guard let newManifest = String(data: newData, encoding: .utf8) else { return (0, 0) }
    setup.manifest = newManifest
    try await setup.save(on: db)

    return (scan.sectionNames.count, writes.count)
}

func applyScriptChangesToZip(
    zipPath: String,
    writes: [String: String],
    deletions: [String]
) throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_apply_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let deletionSet = Set(deletions)

    for entry in listZipEntries(zipPath: zipPath) {
        guard !deletionSet.contains(entry) else { continue }
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    for (filename, content) in writes {
        guard let contentData = content.data(using: .utf8) else {
            throw ScriptZipError.invalidUTF8
        }
        let dest = tempDir.appendingPathComponent(filename)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contentData.write(to: dest)
    }

    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

/// Removes a file from the test setup zip.
/// Throws `ScriptZipError.fileNotFound` if the entry does not exist.
func removeScriptFromZip(zipPath: String, filename: String) throws {
    let entries = listZipEntries(zipPath: zipPath)
    guard entries.contains(filename) else {
        throw ScriptZipError.fileNotFound(filename)
    }
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
        .appendingPathComponent("chickadee_zip_edit_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Extract all entries except the one to remove.
    for entry in entries where entry != filename {
        guard let data = extractZipEntry(zipPath: zipPath, entryName: entry) else { continue }
        let dest = tempDir.appendingPathComponent(entry)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest)
    }

    // Remove old zip and re-create.
    try? fm.removeItem(atPath: zipPath)
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = tempDir
    zip.arguments = ["-q", "-r", zipPath, "."]
    zip.standardOutput = Pipe()
    zip.standardError  = Pipe()
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else { throw ScriptZipError.zipFailed }
}

// MARK: - Manifest update helpers

/// Returns the scripts in the manifest that list `filename` in their `dependsOn`.
func manifestDependents(manifestJSON: String, filename: String) -> [String] {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        return []
    }
    return props.testSuites
        .filter { $0.dependsOn.contains(filename) }
        .map(\.script)
}

/// If the manifest entry for `filename` was produced by a pattern family,
/// returns that family id.  Returns nil for hand-written scripts or missing
/// entries.  Used by the raw-script edit/delete endpoints to reject edits
/// that must instead go through the family editor.
func generatedByFamilyID(manifestJSON: String, filename: String) -> String? {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        return nil
    }
    return props.testSuites.first(where: { $0.script == filename })?.generatedBy
}

/// Returns true when the setup's manifest has at least one test entry
/// (raw script or generated-by-family).  Used by `saveEditedAssignment`
/// to refuse saving an empty suite.
func setupHasAnyTestEntries(manifestJSON: String) throws -> Bool {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data)
    else { return false }
    return !props.testSuites.isEmpty
}

/// Returns updated manifest JSON with a new `TestSuiteEntry` appended.
/// Preserves all existing entries, grading mode, makefile config,
/// starterNotebook, and pattern families.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestAddingScript(
    manifestJSON: String,
    entry: ConfiguredSuiteEntry
) -> String? {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        return nil
    }
    let existing = props.testSuites.enumerated().map { idx, e in
        ConfiguredSuiteEntry(
            script: e.script,
            tier: e.tier.rawValue,
            order: idx + 1,
            dependsOn: e.dependsOn,
            points: e.points,
            displayName: e.name,
            generatedBy: e.generatedBy
        )
    }
    let nextOrder = (existing.map(\.order).max() ?? 0) + 1
    let newEntry = ConfiguredSuiteEntry(
        script: entry.script,
        tier: entry.tier,
        order: nextOrder,
        dependsOn: entry.dependsOn,
        points: entry.points,
        displayName: entry.displayName,
        generatedBy: entry.generatedBy
    )
    let updated = existing + [newEntry]
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: props.patternFamilies
    )
}

/// Returns updated manifest JSON with the entry for `filename` removed.
/// Also clears references to `filename` in other entries' `dependsOn` arrays.
/// Returns `nil` if the manifest JSON cannot be decoded.
func updateManifestRemovingScript(manifestJSON: String, filename: String) -> String? {
    guard let data = manifestJSON.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        return nil
    }
    let updated = props.testSuites
        .filter { $0.script != filename }
        .enumerated()
        .map { idx, e in
            ConfiguredSuiteEntry(
                script: e.script,
                tier: e.tier.rawValue,
                order: idx + 1,
                dependsOn: e.dependsOn.filter { $0 != filename },
                points: e.points,
                displayName: e.name,
                generatedBy: e.generatedBy
            )
        }
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook,
        patternFamilies: props.patternFamilies
    )
}

func extractZipEntry(zipPath: String, entryName: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", zipPath, entryName]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data
}

func buildFileResponse(data: Data, filename: String) -> Response {
    var headers = HTTPHeaders()
    headers.contentType = contentType(for: filename)
    headers.add(name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
    return Response(status: .ok, headers: headers, body: .init(data: data))
}

func contentType(for filename: String) -> HTTPMediaType {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "ipynb", "json":
        return .json
    case "py", "r", "sh", "bash", "zsh", "rb", "pl", "js", "php", "txt", "md", "csv":
        return .plainText
    default:
        return HTTPMediaType(type: "application", subType: "octet-stream")
    }
}

func resolveEditSuiteFiles(
    setupZipPath: String,
    setupManifestJSON: String,
    uploadedSuiteFiles: [File],
    suiteConfigJSON: String?
) throws -> ResolvedEditSuiteFiles {
    let parsedRows: [EditSuiteConfigRow] = {
        guard let raw = suiteConfigJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let rows = try? JSONDecoder().decode([EditSuiteConfigRow].self, from: data) else {
            return []
        }
        return rows
    }()

    // Backward compatibility: no table config submitted.
    // Preserve existing suite/support files and append any new uploads.
    if parsedRows.isEmpty {
        let existingEntries = listZipEntries(zipPath: setupZipPath)
            .filter { $0 != "assignment.ipynb" && $0 != "solution.ipynb" }
            .sorted()

        var resolvedFiles: [File] = []
        var configRows: [ReindexedSuiteConfigRow] = []
        var nextOrder = 1

        let manifestTests: [String: (tier: String, order: Int, dependsOn: [String], points: Int, name: String?)] = {
            guard let data = setupManifestJSON.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
                return [:]
            }
            var map: [String: (tier: String, order: Int, dependsOn: [String], points: Int, name: String?)] = [:]
            for (idx, entry) in props.testSuites.enumerated() {
                map[entry.script] = (entry.tier.rawValue, idx + 1, entry.dependsOn, entry.points, entry.name)
            }
            return map
        }()

        for name in existingEntries {
            guard let data = extractZipEntry(zipPath: setupZipPath, entryName: name) else { continue }
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            resolvedFiles.append(File(data: buffer, filename: name))

            let testInfo = manifestTests[name]
            let tier = testInfo?.tier ?? "support"
            configRows.append(ReindexedSuiteConfigRow(
                index: resolvedFiles.count - 1,
                isTest: testInfo != nil && tier != "support",
                tier: tier,
                order: testInfo?.order ?? nextOrder,
                dependsOn: testInfo?.dependsOn,
                points: testInfo?.points ?? 1,
                displayName: testInfo?.name
            ))
            nextOrder += 1
        }

        let appendedUploads = uploadedSuiteFiles.filter { $0.data.readableBytes > 0 }
        for (idx, file) in appendedUploads.enumerated() {
            let rawName = file.filename.isEmpty ? "suite-file-\(idx + 1)" : file.filename
            let cleanName = sanitizeSuiteFilename(rawName)
            let data = Data(file.data.readableBytesView)
            guard !data.isEmpty else { continue }
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            resolvedFiles.append(File(data: buffer, filename: cleanName))

            let ext = URL(fileURLWithPath: cleanName).pathExtension.lowercased()
            let likelyTest = ["sh","bash","zsh","py","rb","pl","js","php"].contains(ext)
            configRows.append(ReindexedSuiteConfigRow(
                index: resolvedFiles.count - 1,
                isTest: likelyTest,
                tier: likelyTest ? "public" : "support",
                order: nextOrder,
                dependsOn: nil,
                points: 1,
                displayName: nil
            ))
            nextOrder += 1
        }

        let configJSON: String? = {
            guard let data = try? JSONEncoder().encode(configRows) else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        return ResolvedEditSuiteFiles(
            files: resolvedFiles,
            reindexedSuiteConfigJSON: configJSON
        )
    }

    var resolvedFiles: [File] = []
    var configRows: [ReindexedSuiteConfigRow] = []
    var nextOrder = 1

    for row in parsedRows {
        let included = row.isIncluded ?? true
        guard included else { continue }

        let source = (row.source ?? "").lowercased()
        let dataAndName: (Data, String)?
        if source == "existing" {
            guard let rawName = row.name, !rawName.isEmpty else { continue }
            let cleanName = (rawName as NSString).lastPathComponent
            guard cleanName == rawName, !cleanName.isEmpty else { continue }
            guard let data = extractZipEntry(zipPath: setupZipPath, entryName: cleanName) else { continue }
            dataAndName = (data, cleanName)
        } else if source == "upload" {
            guard let idx = row.index, uploadedSuiteFiles.indices.contains(idx) else { continue }
            let file = uploadedSuiteFiles[idx]
            let data = Data(file.data.readableBytesView)
            guard !data.isEmpty else { continue }
            let rawName = file.filename.isEmpty ? "suite-file-\(idx + 1)" : file.filename
            dataAndName = (data, sanitizeSuiteFilename(rawName))
        } else {
            continue
        }

        guard let (data, name) = dataAndName else { continue }

        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        resolvedFiles.append(File(data: buffer, filename: name))

        let tier = normalizeTier(row.tier, isTest: row.isTest)
        let isTest = tier != "support"
        configRows.append(ReindexedSuiteConfigRow(
            index: resolvedFiles.count - 1,
            isTest: isTest,
            tier: tier,
            order: row.order ?? nextOrder,
            dependsOn: row.dependsOn,
            points: row.points ?? 1,
            displayName: row.displayName
        ))
        nextOrder += 1
    }

    let configJSON: String? = {
        guard let data = try? JSONEncoder().encode(configRows) else { return nil }
        return String(data: data, encoding: .utf8)
    }()
    return ResolvedEditSuiteFiles(files: resolvedFiles, reindexedSuiteConfigJSON: configJSON)
}

/// Returned by `loadExistingSolution` with both the file data and the
/// original filename so the edit/save flow can re-submit with the correct name.
struct ExistingSolution {
    let data: Data
    let filename: String
}

struct NewAssignmentDraftFormState: Codable {
    var assignmentName: String
    var dueAt: String
    var sectionID: String
    var requiredPlatform: String
    var requiredArchitecture: String
    var requiredLanguagesCSV: String
    var requiredCapabilitiesCSV: String
    var assignmentNotebookName: String?
    var solutionNotebookName: String?

    static let empty = NewAssignmentDraftFormState(
        assignmentName: "",
        dueAt: "",
        sectionID: "",
        requiredPlatform: "",
        requiredArchitecture: "",
        requiredLanguagesCSV: "",
        requiredCapabilitiesCSV: "",
        assignmentNotebookName: nil,
        solutionNotebookName: nil
    )
}

struct DraftRequirementSuggestions {
    let languages: [String]
    let capabilities: [String]
}

func loadExistingSolution(req: Request, assignment: APIAssignment) async throws -> ExistingSolution? {
    if let validationID = assignment.validationSubmissionID,
       let validationSubmission = try await APISubmission.find(validationID, on: req.db),
       let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
       !data.isEmpty {
        return ExistingSolution(
            data: data,
            filename: validationSubmission.filename ?? "solution.ipynb"
        )
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first(),
       let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
       !data.isEmpty {
        return ExistingSolution(
            data: data,
            filename: fallbackSubmission.filename ?? "solution.ipynb"
        )
    }

    return nil
}

func existingSolutionFilename(req: Request, assignment: APIAssignment) async throws -> String? {
    if let validationID = assignment.validationSubmissionID,
       let validationSubmission = try await APISubmission.find(validationID, on: req.db) {
        return validationSubmission.filename ?? "solution.ipynb"
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .sort(\.$submittedAt, .descending)
        .first() {
        return fallbackSubmission.filename ?? "solution.ipynb"
    }

    return nil
}

func draftFormStateSessionKey(_ draftID: String) -> String {
    "newAssignmentDraft:\(draftID)"
}

func loadDraftFormState(req: Request, draftID: String) -> NewAssignmentDraftFormState {
    guard let raw = req.session.data[draftFormStateSessionKey(draftID)],
          let data = raw.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(NewAssignmentDraftFormState.self, from: data) else {
        return .empty
    }
    return decoded
}

func saveDraftFormState(req: Request, draftID: String, state: NewAssignmentDraftFormState) {
    guard let data = try? JSONEncoder().encode(state),
          let raw = String(data: data, encoding: .utf8) else {
        return
    }
    req.session.data[draftFormStateSessionKey(draftID)] = raw
}

func clearDraftFormState(req: Request, draftID: String) {
    req.session.data[draftFormStateSessionKey(draftID)] = nil
}

func draftNotebookDirectory(testSetupsDirectory: String, setupID: String) -> String {
    testSetupsDirectory + "notebooks/\(setupID)/"
}

func draftSolutionNotebookPath(testSetupsDirectory: String, setupID: String) -> String {
    draftNotebookDirectory(testSetupsDirectory: testSetupsDirectory, setupID: setupID) + "solution.ipynb"
}

func ensureDraftNotebookDirectory(testSetupsDirectory: String, setupID: String) throws -> String {
    let dir = draftNotebookDirectory(testSetupsDirectory: testSetupsDirectory, setupID: setupID)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func draftNotebookData(
    req: Request,
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind,
    fallbackPath: String?
) -> Data? {
    let workingCopyPath = req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
    if let data = try? Data(contentsOf: URL(fileURLWithPath: workingCopyPath)),
       !data.isEmpty,
       (try? JSONSerialization.jsonObject(with: data)) != nil {
        return data
    }
    guard let fallbackPath,
          let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
          !data.isEmpty,
          (try? JSONSerialization.jsonObject(with: data)) != nil else {
        return nil
    }
    return data
}

func removeDraftNotebookFiles(
    req: Request,
    setupID: String,
    userID: UUID,
    fileKind: NotebookFileKind,
    persistedPath: String?
) {
    let workingCopyPath = req.application.directory.publicDirectory
        + "jupyterlite/files/"
        + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: userID, fileKind: fileKind)
    try? FileManager.default.removeItem(atPath: workingCopyPath)
    if let persistedPath {
        try? FileManager.default.removeItem(atPath: persistedPath)
    }
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
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
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
        return newRawEntries.map { .script(AuthoredRawScript(
            script: $0.script,
            tier: TestTier(rawValue: $0.tier) ?? .pub,
            points: $0.points,
            displayName: $0.displayName,
            dependsOn: $0.dependsOn
        )) }
    }
    let newByScript: [String: ConfiguredSuiteEntry] = Dictionary(
        uniqueKeysWithValues: newRawEntries.map { ($0.script, $0) }
    )
    var items: [AuthoredSuiteItem] = []
    var seenFamilies: Set<String> = []
    var seenScripts:  Set<String> = []
    for entry in draftProps.testSuites {
        if let fid = entry.generatedBy {
            guard !seenFamilies.contains(fid) else { continue }
            seenFamilies.insert(fid)
            items.append(.family(id: fid))
        } else {
            guard let newEntry = newByScript[entry.script] else { continue }
            seenScripts.insert(entry.script)
            items.append(.script(AuthoredRawScript(
                script: newEntry.script,
                tier: TestTier(rawValue: newEntry.tier) ?? .pub,
                points: newEntry.points,
                displayName: newEntry.displayName,
                dependsOn: newEntry.dependsOn
            )))
        }
    }
    for newEntry in newRawEntries where !seenScripts.contains(newEntry.script) {
        items.append(.script(AuthoredRawScript(
            script: newEntry.script,
            tier: TestTier(rawValue: newEntry.tier) ?? .pub,
            points: newEntry.points,
            displayName: newEntry.displayName,
            dependsOn: newEntry.dependsOn
        )))
    }
    return items
}

/// Returns one `FamilySuiteRow` per pattern family declared on this setup.
/// Used to populate the family rows in the assignment editor's suite table.
func familySuiteRowsForSetup(_ setup: APITestSetup) -> [FamilySuiteRow] {
    guard let data = setup.manifest.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data)
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

func parsedRequirementCSV(_ raw: String) -> [String] {
    raw
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

func assignmentRequirementSpec(
    platform: String,
    architecture: String,
    languagesCSV: String,
    capabilitiesCSV: String
) -> AssignmentRequirementSpec? {
    let platformValue = platform.trimmingCharacters(in: .whitespacesAndNewlines)
    let architectureValue = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
    let languages = parsedRequirementCSV(languagesCSV)
        .map { AssignmentLanguageRequirement(language: $0.lowercased()) }
    let capabilities = parsedRequirementCSV(capabilitiesCSV)
        .map { RunnerCapability(name: $0.lowercased()) }
    let spec = AssignmentRequirementSpec(
        requiredPlatform: platformValue.isEmpty ? nil : platformValue.lowercased(),
        requiredArchitecture: architectureValue.isEmpty ? nil : architectureValue.lowercased(),
        requiredLanguages: languages,
        requiredCapabilities: capabilities
    )
    guard spec.requiredPlatform != nil
            || spec.requiredArchitecture != nil
            || !spec.requiredLanguages.isEmpty
            || !spec.requiredCapabilities.isEmpty else {
        return nil
    }
    return spec
}

func detectRequirementSuggestions(
    assignmentNotebookData: Data?,
    solutionNotebookData: Data?,
    setup: APITestSetup
) -> DraftRequirementSuggestions {
    var languages = Set<String>()
    var capabilities = Set<String>()

    func addLanguage(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        languages.insert(normalized)
    }

    func addCapability(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        capabilities.insert(normalized)
    }

    func scanPythonSource(_ source: String) {
        for module in pythonCapabilitySuggestions(in: source) {
            addCapability(module)
        }
    }

    func scanNotebook(_ data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let metadata = root["metadata"] as? [String: Any] {
            if let kernelspec = metadata["kernelspec"] as? [String: Any] {
                let name = (kernelspec["name"] as? String ?? "").lowercased()
                let language = (kernelspec["language"] as? String ?? "").lowercased()
                if name == "python" || language == "python" { addLanguage("python") }
                if ["ir", "r", "webr"].contains(name) || language == "r" { addLanguage("r") }
            }
            if let languageInfo = metadata["language_info"] as? [String: Any],
               let language = languageInfo["name"] as? String {
                addLanguage(language)
            }
        }
        guard let cells = root["cells"] as? [[String: Any]] else { return }
        for cell in cells where (cell["cell_type"] as? String) == "code" {
            let source: String
            if let sourceArray = cell["source"] as? [String] {
                source = sourceArray.joined()
            } else {
                source = cell["source"] as? String ?? ""
            }
            scanPythonSource(source)
        }
    }

    func scanZipEntry(name: String, data: Data) {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "py":
            addLanguage("python")
            if let source = String(data: data, encoding: .utf8) {
                scanPythonSource(source)
            }
        case "r":
            addLanguage("r")
        case "sh", "bash":
            addCapability("shell-bash")
        case "zsh":
            addCapability("shell-zsh")
        case "swift":
            addLanguage("swift")
        case "js":
            addLanguage("javascript")
        default:
            break
        }
    }

    if let assignmentNotebookData { scanNotebook(assignmentNotebookData) }
    _ = solutionNotebookData

    for entry in listZipEntries(zipPath: setup.zipPath) {
        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: entry) else { continue }
        scanZipEntry(name: entry, data: data)
    }

    return DraftRequirementSuggestions(
        languages: languages.sorted(),
        capabilities: capabilities.sorted()
    )
}

private func pythonCapabilitySuggestions(in source: String) -> [String] {
    let allowed: [String: String] = [
        "numpy": "numpy",
        "pandas": "pandas",
        "scipy": "scipy",
        "matplotlib": "matplotlib"
    ]
    let patterns = [
        #"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*)"#,
        #"(?m)^\s*from\s+([A-Za-z_][A-Za-z0-9_\.]*)\s+import\s+"#
    ]
    var matches = Set<String>()
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let nsrange = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: nsrange) where match.numberOfRanges > 1 {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let root = source[range].split(separator: ".").first.map(String.init)?.lowercased() ?? ""
            if let capability = allowed[root] {
                matches.insert(capability)
            }
        }
    }
    return matches.sorted()
}

func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

func multipartParts(from req: Request) throws -> [MultipartPart]? {
    guard let contentType = req.headers.contentType,
          contentType.type == "multipart",
          contentType.subType == "form-data",
          let boundary = contentType.parameters["boundary"],
          let body = req.body.data else {
        return nil
    }

    let parser = MultipartParser(boundary: boundary)
    var parts: [MultipartPart] = []
    var headers = HTTPHeaders()
    var partBody = ByteBuffer()

    parser.onHeader = { field, value in
        headers.replaceOrAdd(name: field, value: value)
    }
    parser.onBody = { chunk in
        partBody.writeBuffer(&chunk)
    }
    parser.onPartComplete = {
        parts.append(MultipartPart(headers: headers, body: partBody))
        headers = HTTPHeaders()
        partBody = ByteBuffer()
    }

    try parser.execute(body)
    return parts
}

func multipartFiles(named names: [String], from req: Request) throws -> [File]? {
    guard let parts = try multipartParts(from: req) else { return nil }
    let files = names
        .flatMap { name in parts.allParts(named: name) }
        .compactMap(File.init(multipart:))
    return files.isEmpty ? nil : files
}

func multipartTextField(named names: [String], from req: Request) throws -> String? {
    guard let parts = try multipartParts(from: req) else { return nil }
    for name in names {
        if let part = parts.firstPart(named: name),
           let value = String(multipart: part) {
            return value
        }
    }
    return nil
}

func nextAssignmentSortOrder(req: Request) async throws -> Int {
    let maxOrder = try await APIAssignment.query(on: req.db)
        .all()
        .compactMap(\.sortOrder)
        .max() ?? 0
    return maxOrder + 1
}

/// Returns the earned points for a submission result, suitable for LEARN-style CSV export.
/// Tries Double first (for fractional points), falls back to Int for older results.
/// When earnedPoints/totalPoints are absent, falls back to passCount.
func gradePointsFromCollectionJSON(_ collectionJSON: String) -> Double? {
    guard let data = collectionJSON.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    // Prefer weighted points when present (non-nil and non-zero totalPoints).
    let totalPoints = (root["totalPoints"] as? Double) ?? (root["totalPoints"] as? Int).map(Double.init)
    if let total = totalPoints, total > 0 {
        let earned = (root["earnedPoints"] as? Double) ?? (root["earnedPoints"] as? Int).map(Double.init)
        if let e = earned { return e }
    }
    // Fall back to pass count for old results.
    let passCount = (root["passCount"] as? Double) ?? (root["passCount"] as? Int).map(Double.init)
    return passCount
}

func gradePercentFromCollectionJSON(_ collectionJSON: String) -> Int? {
    guard let data = collectionJSON.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    // Prefer weighted points when present (non-nil and non-zero totalPoints).
    if let earnedPoints = root["earnedPoints"] as? Int,
       let totalPoints  = root["totalPoints"]  as? Int,
       totalPoints > 0 {
        return Int((Double(earnedPoints) / Double(totalPoints) * 100).rounded())
    }
    // Fall back to unweighted count for old results.
    guard let passCount  = root["passCount"]  as? Int,
          let totalTests = root["totalTests"] as? Int,
          totalTests > 0 else { return nil }
    return Int((Double(passCount) / Double(totalTests) * 100).rounded())
}

func csvEscaped(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return value
}

func inferNameFromStudentID(_ studentID: String) -> (surname: String, givenNames: String) {
    let raw = studentID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return ("—", "—") }

    if let parsed = splitHumanName(raw), raw.contains(",") { return parsed }
    return ("—", "—")
}

func defaultNotebookData(title: String) -> Data {
    let safeTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
    let json = """
    {
      "cells": [
        {
          "cell_type": "markdown",
          "metadata": {},
          "source": ["# \(safeTitle)\\n", "\\n", "Write your assignment instructions here.\\n"]
        },
        {
          "cell_type": "code",
          "execution_count": null,
          "metadata": {},
          "outputs": [],
          "source": ["# Student solution starts here\\n"]
        }
      ],
      "metadata": {
        "kernelspec": {
          "display_name": "Python (Pyodide)",
          "language": "python",
          "name": "python"
        },
        "language_info": {
          "name": "python"
        }
      },
      "nbformat": 4,
      "nbformat_minor": 5
    }
    """
    return Data(json.utf8)
}

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
          var rows = (try? JSONSerialization.jsonObject(with: configData)) as? [[String: Any]] else {
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
                  let data = extractZipEntry(zipPath: zipPath, entryName: name) {
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
          let updatedJSON = String(data: updatedData, encoding: .utf8) else {
        return (mergedFiles, suiteConfigJSON)
    }
    return (mergedFiles, updatedJSON)
}

func createRunnerSetupZip(
    suiteFiles: [File],
    suiteConfigJSON: String?,
    zipPath: String
) throws -> RunnerSetupPackage {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("chickadee_runner_setup_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    var seenNames: Set<String> = []
    var storedNameByIndex: [Int: String] = [:]
    for (index, file) in suiteFiles.enumerated() {
        let data = Data(file.data.readableBytesView)
        guard !data.isEmpty else { continue }
        let rawName = file.filename.isEmpty ? "suite-file-\(index + 1)" : file.filename
        let baseName = sanitizeSuiteFilename(rawName)
        let finalName: String
        if !seenNames.contains(baseName) {
            finalName = baseName
        } else {
            let ext = URL(fileURLWithPath: baseName).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            var suffix = 2
            var candidate = baseName
            while seenNames.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                suffix += 1
            }
            finalName = candidate
        }
        seenNames.insert(finalName)
        try data.write(to: tempDir.appendingPathComponent(finalName))
        storedNameByIndex[index] = finalName
    }

    // Neither assignment.ipynb nor solution.ipynb belong in the runner zip.
    //
    // assignment.ipynb is the starter template served to students via
    // JupyterLite (from notebooks/{setupID}/ on disk).  The runner doesn't
    // need it — the student provides their own submission.  Having it in the
    // working directory forces the runner to delete it before tests run so
    // grading scripts don't see two notebooks.
    //
    // solution.ipynb is persisted separately as a validation-submission
    // artifact.  Including it would produce duplicate .py definitions.

    let testSuites = try buildSuiteEntries(
        suiteFiles: suiteFiles,
        storedNameByIndex: storedNameByIndex,
        suiteConfigJSON: suiteConfigJSON
    )

    if storedNameByIndex.isEmpty {
        try writeEmptyZip(to: zipPath)
    } else {
        // Rebuilding an existing setup zip must start from a clean archive.
        // `zip -r existing.zip .` updates/adds entries but does not remove files
        // that are absent from the new source directory, which makes deleted
        // suite/support files reappear on the next edit.
        try? fm.removeItem(atPath: zipPath)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir
        zip.arguments = ["-q", "-r", zipPath, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw Abort(.internalServerError, reason: "Failed to package setup zip")
        }
    }
    let hasMakefile = storedNameByIndex.values.contains {
        let n = $0.lowercased()
        return n == "makefile" || n == "gnumakefile"
    }
    return RunnerSetupPackage(testSuites: testSuites, hasMakefile: hasMakefile)
}

private func writeEmptyZip(to path: String) throws {
    let emptyZip = Data([
        0x50, 0x4b, 0x05, 0x06,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00
    ])
    try emptyZip.write(to: URL(fileURLWithPath: path))
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
              let rows = try? JSONDecoder().decode([SuiteConfigRow].self, from: data) else {
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
            selected.append(ConfiguredSuiteEntry(
                script: script,
                tier: tier,
                order: row.order ?? (index + 1),
                dependsOn: row.dependsOn ?? [],
                points: row.points ?? 1,
                displayName: row.displayName
            ))
        }
        return selected
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
        defaults.append(ConfiguredSuiteEntry(
            script: script,
            tier: "public",
            order: inferredOrder(from: script) ?? (index + 1),
            dependsOn: [],
            points: 1,
            displayName: nil
        ))
    }
    return defaults
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
          let orderRange = Range(match.range(at: 1), in: base) else {
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
    let supportedExtensions: Set<String> = ["sh", "bash", "zsh", "py", "r", "rb", "pl", "js", "php"]
    let ext = URL(fileURLWithPath: storedName).pathExtension.lowercased()
    if supportedExtensions.contains(ext) { return true }
    guard ext.isEmpty else { return false }
    return hasRecognizedScriptShebang(file)
}

func hasRecognizedScriptShebang(_ file: File) -> Bool {
    let prefix = String(decoding: Data(file.data.readableBytesView.prefix(256)), as: UTF8.self)
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
    return false
}

func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool,
    gradingMode: String = "worker",
    starterNotebook: String? = "assignment.ipynb",
    patternFamilies: [PatternFamily] = [],
    notebookChecks: [NotebookCheck] = [],
    sections: [TestSuiteSection] = []
) throws -> String {
    // Topologically sort so the runner can process dependencies with a single
    // linear pass (parents always appear before children in the array).
    let sorted = topologicallySorted(testSuites)

    let testSuiteJSON: [[String: Any]] = sorted.map { entry in
        var dict: [String: Any] = ["tier": entry.tier, "script": entry.script]
        if let n = entry.displayName, !n.isEmpty {
            dict["name"] = n
        }
        if !entry.dependsOn.isEmpty {
            dict["dependsOn"] = entry.dependsOn
        }
        if entry.points > 1 {
            dict["points"] = entry.points
        }
        if let fid = entry.generatedBy, !fid.isEmpty {
            dict["generatedBy"] = fid
        }
        if let cid = entry.generatedByCheck, !cid.isEmpty {
            dict["generatedByCheck"] = cid
        }
        if let sid = entry.sectionID, !sid.isEmpty {
            dict["sectionID"] = sid
        }
        return dict
    }
    var manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": gradingMode,
        "requiredFiles": [],
        "testSuites": testSuiteJSON,
        "timeLimitSeconds": 10,
        "makefile": includeMakefile ? ["target": NSNull()] : NSNull()
    ]
    if let starterNotebook {
        manifest["starterNotebook"] = starterNotebook
    }
    if !patternFamilies.isEmpty {
        // Encode the typed family values via JSONEncoder (keys sorted for
        // reproducibility), then reparse with JSONSerialization so they
        // splice into the dictionary-of-Any shape used here.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let familyData = try encoder.encode(patternFamilies)
        if let parsed = try JSONSerialization.jsonObject(with: familyData) as? [Any] {
            manifest["patternFamilies"] = parsed
        }
    }
    if !notebookChecks.isEmpty {
        // Same encode-then-reparse trick as patternFamilies above.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let checksData = try encoder.encode(notebookChecks)
        if let parsed = try JSONSerialization.jsonObject(with: checksData) as? [Any] {
            manifest["notebookChecks"] = parsed
        }
    }
    if !sections.isEmpty {
        // Route sections through JSONEncoder (same pattern patternFamilies
        // uses above) so all fields — including `variables` (v0.4.100+)
        // — round-trip through the manifest.  Pre-v0.4.102 we hand-
        // rolled a minimal `[id, name]` dict that silently dropped the
        // section's variables on every save, which meant any family
        // CRUD or suite PUT wiped shared inputs the instructor had
        // just declared.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sectionData = try encoder.encode(sections)
        if let parsed = try JSONSerialization.jsonObject(with: sectionData) as? [Any] {
            manifest["sections"] = parsed
        }
    }
    let data = try JSONSerialization.data(withJSONObject: manifest)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Returns `entries` in topological order (prerequisites before dependents)
/// while honouring authored position as tightly as the dependency graph
/// allows.
///
/// Uses Kahn's algorithm but with an **authored-position priority queue**
/// instead of FIFO.  At each step we emit the ready node (inDegree == 0)
/// with the smallest original index.  This preserves the instructor's
/// suite-editor order whenever the dependency graph doesn't force a
/// different ordering — e.g. a family that depends on `publictest_a.py`
/// and is authored right after it stays right after it, rather than
/// being demoted to the tail by a FIFO queue that processes trailing
/// no-dep scripts before satisfied dependents re-enter.
///
/// Regression guard: `testApply_familyWithDependencyStaysInlineAfterPrereq`
/// (v0.4.95).
private func topologicallySorted(_ entries: [ConfiguredSuiteEntry]) -> [ConfiguredSuiteEntry] {
    var inDegree:   [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    var byScript:   [String: ConfiguredSuiteEntry] = [:]
    var origIdx:    [String: Int] = [:]

    for (i, entry) in entries.enumerated() {
        byScript[entry.script] = entry
        origIdx[entry.script]  = i
        inDegree[entry.script, default: 0] += 0
        for dep in entry.dependsOn {
            dependents[dep, default: []].append(entry.script)
            inDegree[entry.script, default: 0] += 1
        }
    }

    var ready: Set<String> = Set(
        entries.filter { inDegree[$0.script, default: 0] == 0 }.map(\.script)
    )
    var result: [ConfiguredSuiteEntry] = []
    result.reserveCapacity(entries.count)
    while !ready.isEmpty {
        // Pop the ready node with the smallest authored index — that's
        // what keeps a family in-line with its prereq rather than
        // letting downstream no-dep scripts jump ahead of it.
        guard let nodeName = ready.min(by: {
            (origIdx[$0] ?? 0) < (origIdx[$1] ?? 0)
        }), let entry = byScript[nodeName] else { break }
        ready.remove(nodeName)
        result.append(entry)
        for dependent in dependents[nodeName] ?? [] {
            inDegree[dependent, default: 1] -= 1
            if inDegree[dependent, default: 0] == 0 {
                ready.insert(dependent)
            }
        }
    }
    // Fall back to original order if a cycle somehow slipped through
    // upstream validation.
    return result.count == entries.count ? result : entries
}

func enqueueRunnerValidationSubmission(
    req: Request,
    setupID: String,
    solutionNotebookData: Data,
    filename: String = "solution.ipynb"
) async throws -> String {
    let sanitizedFilename = submissionFilenameForStorage(
        uploadedName: filename,
        fallback: "solution.ipynb"
    )
    let submissionsDir = req.application.submissionsDirectory
    let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
    let ext = (sanitizedFilename as NSString).pathExtension
    let filePath = submissionsDir + "\(subID).\(ext)"
    try solutionNotebookData.write(to: URL(fileURLWithPath: filePath))

    let priorCount = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .count()

    let user = try req.auth.require(APIUser.self)
    let submission = APISubmission(
        id:            subID,
        testSetupID:   setupID,
        zipPath:       filePath,
        attemptNumber: priorCount + 1,
        filename:      sanitizedFilename,
        userID:        user.id,
        kind:          APISubmission.Kind.validation
    )
    try await submission.save(on: req.db)
    return subID
}

/// Schedule a validation submission after a suite edit, best-effort.
/// Looks up the most recent solution notebook (either the currently linked
/// validation submission or the most recent validation for this setup) and
/// enqueues a fresh validation so the runner picks up the new manifest.
///
/// Debounced: if there's already a pending (unclaimed) validation for this
/// setup, we skip — the runner will pick that one up with the freshest
/// manifest (the test setup download URL carries a hash of manifest bytes,
/// so an in-flight submission still pulls the updated zip + manifest).
///
/// Pre-checks that a runner compatible with the assignment's
/// `AssignmentRequirement` is available before enqueueing.  If none is
/// available (and local-runner-autostart can't bring one up), the
/// validation is *not* enqueued and `validationStatus` is set to
/// `"no-runner"` so the assignments list shows a specific reason
/// instead of a perpetual "pending".  Pre-v0.4.130 the validation went
/// in regardless and silently sat in queue forever.
///
/// Errors are swallowed: this is a nice-to-have trigger from live-edit
/// endpoints and must not block the edit save.
func scheduleValidationAfterSuiteEdit(
    req: Request,
    assignment: APIAssignment
) async {
    do {
        let existingPending = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .filter(\.$status == "pending")
            .first()
        if existingPending != nil { return }

        guard let solution = try await loadExistingSolution(req: req, assignment: assignment)
        else { return }

        let requirementSpec = try await loadAssignmentRequirementSpec(
            assignment: assignment,
            on: req.db
        )
        let hasRunner = try await ensureCompatibleValidationRunnerAvailability(
            req: req,
            requirements: requirementSpec
        )
        guard hasRunner else {
            assignment.validationStatus = "no-runner"
            try await assignment.save(on: req.db)
            return
        }

        let subID = try await enqueueRunnerValidationSubmission(
            req: req,
            setupID: assignment.testSetupID,
            solutionNotebookData: solution.data,
            filename: solution.filename
        )
        assignment.validationSubmissionID = subID
        assignment.validationStatus = "pending"
        try await assignment.save(on: req.db)
    } catch {
        req.logger.warning("scheduleValidationAfterSuiteEdit: \(error)")
    }
}

/// Loads the persisted `AssignmentRequirement` for an assignment, if any,
/// and decodes it into an `AssignmentRequirementSpec`.  Used by the
/// validation pre-check to pick the right runner profile.
func loadAssignmentRequirementSpec(
    assignment: APIAssignment,
    on db: Database
) async throws -> AssignmentRequirementSpec? {
    guard let assignmentID = assignment.id else { return nil }
    let row = try await AssignmentRequirement.query(on: db)
        .filter(\.$assignmentID == assignmentID)
        .first()
    return row?.requirementSpec
}

/// Re-queues every student submission for a test setup so the worker
/// regrades them against the current manifest.  Introduced in v0.4.93 to
/// close the loop on assignment revisions: after an instructor fixes a
/// bug in the test suite (or edits a pattern family), every prior
/// submission gets a fresh result computed against the new grading logic.
///
/// Scope decisions (from v0.4.93 design):
/// - **Every submission**, not just the latest per student — the caller's
///   call.  At ~1s/submission on two runners, 150 students × a few
///   attempts = ~10 min total, acceptable queue latency for this use.
/// - **Excludes `kind = .validation`.**  The instructor's solution
///   notebook re-validates via `scheduleValidationAfterSuiteEdit`, which
///   enqueues a fresh validation row; bumping the old one would
///   double-enqueue.
/// - **Browser-graded submissions get handled automatically** — the
///   v0.4.56 worker backstop already treats any pending submission as a
///   candidate, running the generated `.py` scripts natively via
///   `python3`.  Flipping `status = "pending"` is enough.
/// - **Idempotent against in-flight retests.**  Submissions already in
///   `pending` / `assigned` are skipped unless `force = true`, so
///   rapid-fire saves (or the manual "Retest all" button after an
///   auto-retest already fired) don't double-queue the same row.
/// - **Does not mutate `lastRetestedManifestHash` on the setup** — the
///   caller owns that bookkeeping (the helper can be invoked for a
///   setup-hash-unchanged save via the explicit button).
///
/// Returns the number of submissions whose status was flipped to pending.
@discardableResult
func retestAllSubmissionsForSetup(
    setupID: String,
    triggeredBy userID: UUID?,
    on db: Database,
    force: Bool = false
) async throws -> Int {
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == setupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()

    let now = Date()
    var touched = 0
    for submission in submissions {
        if !force && (submission.status == "pending" || submission.status == "assigned") {
            continue
        }
        submission.status = "pending"
        submission.workerID = nil
        submission.assignedAt = nil
        submission.retestedAt = now
        submission.retestedByUserID = userID
        try await submission.save(on: db)
        touched += 1
    }
    return touched
}

/// SHA-256 hex digest of `setup.manifest`.  Used by the auto-retest
/// trigger as the dedup key for "manifest unchanged since last retest".
func manifestHash(_ manifestJSON: String) -> String {
    let digest = SHA256.hash(data: Data(manifestJSON.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func waitForRunnerValidation(
    req: Request,
    submissionID: String,
    timeoutSeconds: TimeInterval = 20
) async throws -> RunnerValidationOutcome {
    let started = Date()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    while Date().timeIntervalSince(started) < timeoutSeconds {
        guard let submission = try await APISubmission.find(submissionID, on: req.db),
              submission.kind == APISubmission.Kind.validation else {
            throw Abort(.notFound, reason: "Validation submission missing")
        }

        if submission.status == "complete" || submission.status == "failed" {
            guard let result = try await APIResult.query(on: req.db)
                .filter(\.$submissionID == submissionID)
                .sort(\.$receivedAt, .descending)
                .first(),
                  let data = result.collectionJSON.data(using: .utf8) else {
                return .failed(summary: "no result payload")
            }

            let collection = try decoder.decode(TestOutcomeCollection.self, from: data)
            let summary = "\(collection.passCount)/\(collection.totalTests) passed"
            let passed = collection.buildStatus == .passed &&
                collection.failCount == 0 &&
                collection.errorCount == 0 &&
                collection.timeoutCount == 0
            return passed ? .passed(summary: summary) : .failed(summary: summary)
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    return .timedOut
}

func ensureValidationRunnerAvailability(req: Request) async {
    let enabled = await req.application.localRunnerAutoStartStore.isEnabled()
    guard enabled else { return }

    let hasRecentRunner = await req.application.workerActivityStore.hasRecentActivity(within: 20)
    guard !hasRecentRunner else { return }

    await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}

func hasCompatibleValidationRunner(
    req: Request,
    requirements: AssignmentRequirementSpec?,
    activeWindowSeconds: TimeInterval = 20
) async throws -> Bool {
    try await req.application.runnerProfiles.refreshActiveFlags(
        activeWindowSeconds: activeWindowSeconds,
        on: req.db
    )

    let profiles = try await RunnerProfile.query(on: req.db)
        .filter(\.$isActive == true)
        .all()
    let matcher = CompatibilityMatcher()

    return profiles.contains { profile in
        matcher.evaluate(
            runnerProfile: profile.capabilityProfile,
            requirements: requirements
        ).isCompatible
    }
}

func ensureCompatibleValidationRunnerAvailability(
    req: Request,
    requirements: AssignmentRequirementSpec?,
    activeWindowSeconds: TimeInterval = 20,
    attempts: Int = 3
) async throws -> Bool {
    if try await hasCompatibleValidationRunner(
        req: req,
        requirements: requirements,
        activeWindowSeconds: activeWindowSeconds
    ) {
        return true
    }

    let enabled = await req.application.localRunnerAutoStartStore.isEnabled()
    guard enabled else { return false }

    await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)

    for attempt in 0..<attempts {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if try await hasCompatibleValidationRunner(
            req: req,
            requirements: requirements,
            activeWindowSeconds: activeWindowSeconds
        ) {
            return true
        }

        if attempt + 1 < attempts {
            await req.application.localRunnerManager.ensureRunning(app: req.application, logger: req.logger)
        }
    }

    return false
}

func removeMaterializedNotebookFiles(req: Request, setupID: String) {
    let roots = [
        req.application.directory.publicDirectory + "files/",
        req.application.directory.publicDirectory + "jupyterlite/files/",
        req.application.directory.publicDirectory + "jupyterlite/lab/files/",
        req.application.directory.publicDirectory + "jupyterlite/notebooks/files/"
    ]
    for root in roots {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for name in entries where name.hasPrefix(setupID) && name.hasSuffix(".ipynb") {
            try? FileManager.default.removeItem(atPath: root + name)
        }
    }
}

// MARK: - Support file extraction

/// Extracts "support" files (zip entries that are neither test suite scripts nor the
/// canonical notebooks) to `{testSetupsDirectory}/shared/{setupID}/`.
///
/// Called after every test setup create/update so the shared directory always reflects
/// the current zip contents. The runner is unaffected — it re-extracts the full zip
/// to a temp directory per job.
func extractSupportFilesToSharedDirectory(
    zipPath: String,
    setupID: String,
    testSuiteScripts: Set<String>,
    testSetupsDirectory: String
) {
    let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]
    let allEntries = listZipEntries(zipPath: zipPath)
    let supportNames = allEntries.filter {
        !testSuiteScripts.contains($0) && !reservedNames.contains($0)
    }

    let sharedDir = testSetupsDirectory + "shared/\(setupID)/"
    let fm = FileManager.default
    do {
        // Always remove the stale shared dir before re-extracting so a support
        // file removed on edit doesn't linger (and so student symlinks to it
        // become visibly broken rather than silently stale).
        if fm.fileExists(atPath: sharedDir) {
            try fm.removeItem(atPath: sharedDir)
        }
        guard !supportNames.isEmpty else { return }
        try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        for name in supportNames {
            guard let data = extractZipEntry(zipPath: zipPath, entryName: name) else { continue }
            let destination = URL(fileURLWithPath: sharedDir + name)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
        }
    } catch {
        // Non-fatal: support files are a convenience; log and continue.
        // (Structured logging not available in a free function; print suffices here.)
        print("[chickadee] Warning: failed to extract support files for \(setupID): \(error)")
    }
}
