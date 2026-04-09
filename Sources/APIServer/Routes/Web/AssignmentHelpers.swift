// APIServer/Routes/Web/AssignmentHelpers.swift
//
// Private free functions and helper types for assignment management routes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation

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

func currentSetupFiles(for setup: APITestSetup, assignmentID: String, hasValidationSolution: Bool) -> (
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

    let manifestSuites: [(script: String, tier: String, order: Int, dependsOn: [String], points: Int, name: String?)] = {
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
            return []
        }
        return props.testSuites.enumerated().map { (idx, item) in
            (script: item.script, tier: item.tier.rawValue, order: idx + 1,
             dependsOn: item.dependsOn, points: item.points, name: item.name)
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
        if hasValidationSolution {
            return CurrentFileLink(name: "solution.ipynb", url: "/instructor/\(assignmentID)/files/solution")
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

    let existingSuiteRows = nonNotebookFiles.enumerated().map { idx, name in
        let entry = testMap[name]
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

/// Returns updated manifest JSON with a new `TestSuiteEntry` appended.
/// Preserves all existing entries, grading mode, makefile config, and starterNotebook.
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
            displayName: e.name
        )
    }
    let nextOrder = (existing.map(\.order).max() ?? 0) + 1
    let newEntry = ConfiguredSuiteEntry(
        script: entry.script,
        tier: entry.tier,
        order: nextOrder,
        dependsOn: entry.dependsOn,
        points: entry.points,
        displayName: entry.displayName
    )
    let updated = existing + [newEntry]
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook
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
                displayName: e.name
            )
        }
    return try? makeWorkerManifestJSON(
        testSuites: updated,
        includeMakefile: props.makefile != nil,
        gradingMode: props.gradingMode.rawValue,
        starterNotebook: props.starterNotebook
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

    let manifestTests: [String: (tier: String, order: Int, dependsOn: [String], points: Int, name: String?)] = {
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
            return [:]
        }
        var map: [String: (tier: String, order: Int, dependsOn: [String], points: Int, name: String?)] = [:]
        for (idx, entry) in props.testSuites.enumerated() {
            map[entry.script] = (entry.tier.rawValue, idx + 1, entry.dependsOn, entry.points, entry.name)
        }
        return map
    }()

    return entries.enumerated().map { idx, name in
        let info = manifestTests[name]
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
    if let solutionNotebookData { scanNotebook(solutionNotebookData) }

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
    let supportedExtensions: Set<String> = ["sh", "bash", "zsh", "py", "r", "rb", "pl", "js", "php"]
    var defaults: [ConfiguredSuiteEntry] = []
    for index in suiteFiles.indices {
        guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
        let ext = URL(fileURLWithPath: script).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { continue }
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

func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool,
    gradingMode: String = "worker",
    starterNotebook: String? = "assignment.ipynb"
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
    let data = try JSONSerialization.data(withJSONObject: manifest)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Returns `entries` in topological order (prerequisites before dependents).
/// Entries with no dependencies are emitted first in their original relative order.
/// If the graph has no cycles (guaranteed by upload-time validation), this
/// always produces a valid ordering.
private func topologicallySorted(_ entries: [ConfiguredSuiteEntry]) -> [ConfiguredSuiteEntry] {
    var inDegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]
    var byScript: [String: ConfiguredSuiteEntry] = [:]

    for entry in entries {
        byScript[entry.script] = entry
        inDegree[entry.script, default: 0] += 0
        for dep in entry.dependsOn {
            dependents[dep, default: []].append(entry.script)
            inDegree[entry.script, default: 0] += 1
        }
    }

    // Maintain original relative order among entries with equal in-degree.
    var queue = entries.filter { inDegree[$0.script, default: 0] == 0 }
    var result: [ConfiguredSuiteEntry] = []
    while !queue.isEmpty {
        let node = queue.removeFirst()
        result.append(node)
        let children = (dependents[node.script] ?? [])
            .compactMap { byScript[$0] }
            .sorted { lhs, rhs in
                // Preserve original order among siblings.
                let li = entries.firstIndex(where: { $0.script == lhs.script }) ?? 0
                let ri = entries.firstIndex(where: { $0.script == rhs.script }) ?? 0
                return li < ri
            }
        for child in children {
            inDegree[child.script, default: 1] -= 1
            if inDegree[child.script, default: 0] == 0 {
                queue.append(child)
            }
        }
    }
    // Fall back to original order if cycle somehow slipped through.
    return result.isEmpty ? entries : result
}

func enqueueRunnerValidationSubmission(
    req: Request,
    setupID: String,
    solutionNotebookData: Data,
    filename: String = "solution.ipynb"
) async throws -> String {
    let submissionsDir = req.application.submissionsDirectory
    let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
    let ext = (filename as NSString).pathExtension
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
        filename:      filename,
        userID:        user.id,
        kind:          APISubmission.Kind.validation
    )
    try await submission.save(on: req.db)
    return subID
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
