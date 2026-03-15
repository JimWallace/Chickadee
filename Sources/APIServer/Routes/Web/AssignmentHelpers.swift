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
}

struct ResolvedEditSuiteFiles {
    let files: [File]
    let reindexedSuiteConfigJSON: String?
}

struct SuiteConfigRow: Decodable {
    let index: Int
    let isTest: Bool
    let tier: String?
    let order: Int?
    let dependsOn: [String]?   // script names of prerequisites
    let points: Int?           // grade weight; nil decoded as 1
}

struct ConfiguredSuiteEntry {
    let script: String
    let tier: String
    let order: Int
    let dependsOn: [String]    // script names of prerequisites; empty == none
    let points: Int            // grade weight; 1 = default (unweighted)
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
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.date(from: raw)
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

    let expectedPrefix = "/assignments/\(assignmentIDRaw)"
    guard path == expectedPrefix || path.hasPrefix(expectedPrefix + "/") else {
        return fallbackPath
    }
    return path
}

func dueAtLocalInputString(_ date: Date?) -> String {
    guard let date else { return "" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return fmt.string(from: date)
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
            url: "/assignments/\(assignmentID)/files/notebook"
        )
    }()

    let manifestSuites: [(script: String, tier: String, order: Int, dependsOn: [String], points: Int)] = {
        guard let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
            return []
        }
        return props.testSuites.enumerated().map { (idx, item) in
            (script: item.script, tier: item.tier.rawValue, order: idx + 1, dependsOn: item.dependsOn, points: item.points)
        }
    }()
    let testMap = Dictionary(uniqueKeysWithValues: manifestSuites.map { ($0.script, $0) })

    let archiveFiles = listZipEntries(zipPath: setup.zipPath)
    let solutionFile: CurrentFileLink? = {
        if archiveFiles.contains("solution.ipynb") {
            return CurrentFileLink(
                name: "solution.ipynb",
                url: "/assignments/\(assignmentID)/files/item?name=solution.ipynb"
            )
        }
        if hasValidationSolution {
            return CurrentFileLink(name: "solution.ipynb", url: "/assignments/\(assignmentID)/files/solution")
        }
        return nil
    }()

    let nonNotebookFiles = archiveFiles
        .filter { $0 != "assignment.ipynb" && $0 != "solution.ipynb" }
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
            url: "/assignments/\(assignmentID)/files/item?name=\(urlEncode(name))",
            isTest: entry != nil,
            tier: entry?.tier ?? "support",
            order: entry?.order ?? (idx + 1),
            dependsOn: entry?.dependsOn ?? [],
            points: entry?.points ?? 1
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
        .filter { !$0.isEmpty && !$0.hasSuffix("/") }
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

        let manifestTests: [String: (tier: String, order: Int, dependsOn: [String], points: Int)] = {
            guard let data = setupManifestJSON.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
                return [:]
            }
            var map: [String: (tier: String, order: Int, dependsOn: [String], points: Int)] = [:]
            for (idx, entry) in props.testSuites.enumerated() {
                map[entry.script] = (entry.tier.rawValue, idx + 1, entry.dependsOn, entry.points)
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
                points: testInfo?.points ?? 1
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
                points: 1
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

        let tier = normalizeTier(row.tier)
        let isTest = (row.isTest ?? false) && tier != "support"
        configRows.append(ReindexedSuiteConfigRow(
            index: resolvedFiles.count - 1,
            isTest: isTest,
            tier: tier,
            order: row.order ?? nextOrder,
            dependsOn: row.dependsOn,
            points: row.points ?? 1
        ))
        nextOrder += 1
    }

    let configJSON: String? = {
        guard let data = try? JSONEncoder().encode(configRows) else { return nil }
        return String(data: data, encoding: .utf8)
    }()
    return ResolvedEditSuiteFiles(files: resolvedFiles, reindexedSuiteConfigJSON: configJSON)
}

func loadExistingSolutionNotebook(req: Request, assignment: APIAssignment) async throws -> Data? {
    if let validationID = assignment.validationSubmissionID,
       let validationSubmission = try await APISubmission.find(validationID, on: req.db),
       let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
       !data.isEmpty {
        return data
    }

    if let fallbackSubmission = try await APISubmission.query(on: req.db)
        .filter(\.$testSetupID == assignment.testSetupID)
        .filter(\.$kind == APISubmission.Kind.validation)
        .filter(\.$filename == "solution.ipynb")
        .sort(\.$submittedAt, .descending)
        .first(),
       let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
       !data.isEmpty {
        return data
    }

    return nil
}

func urlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}

func nextAssignmentSortOrder(req: Request) async throws -> Int {
    let maxOrder = try await APIAssignment.query(on: req.db)
        .all()
        .compactMap(\.sortOrder)
        .max() ?? 0
    return maxOrder + 1
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

    if raw.contains(",") {
        let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let surname = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let given = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (
            surname.isEmpty ? "—" : surname,
            given.isEmpty ? "—" : given
        )
    }
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
    assignmentNotebookData: Data,
    solutionNotebookData: Data?,
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

    let notebookURL = tempDir.appendingPathComponent("assignment.ipynb")
    try assignmentNotebookData.write(to: notebookURL)
    if let solutionNotebookData {
        let solutionURL = tempDir.appendingPathComponent("solution.ipynb")
        try solutionNotebookData.write(to: solutionURL)
    }

    let testSuites = try buildSuiteEntries(
        suiteFiles: suiteFiles,
        storedNameByIndex: storedNameByIndex,
        suiteConfigJSON: suiteConfigJSON
    )
    guard !testSuites.isEmpty else {
        throw Abort(.badRequest, reason: "Select at least one test file in the suite file list")
    }

    // Remove old zip first — /usr/bin/zip -r appends to existing archives,
    // so deleted files would persist if we don't start fresh.
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
    let hasMakefile = storedNameByIndex.values.contains {
        let n = $0.lowercased()
        return n == "makefile" || n == "gnumakefile"
    }
    return RunnerSetupPackage(testSuites: testSuites, hasMakefile: hasMakefile)
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
            guard let row = rowsByIndex[index], row.isTest else { continue }
            guard let script = storedNameByIndex[index], !script.isEmpty else { continue }
            let tier = normalizeTier(row.tier)
            selected.append(ConfiguredSuiteEntry(
                script: script,
                tier: tier,
                order: row.order ?? (index + 1),
                dependsOn: row.dependsOn ?? [],
                points: row.points ?? 1
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
            points: 1
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

func normalizeTier(_ raw: String?) -> String {
    switch (raw ?? "public").lowercased() {
    case "secret": return "secret"
    case "release": return "release"
    default: return "public"
    }
}

func makeWorkerManifestJSON(
    testSuites: [ConfiguredSuiteEntry],
    includeMakefile: Bool,
    gradingMode: String = "worker"
) throws -> String {
    // Topologically sort so the runner can process dependencies with a single
    // linear pass (parents always appear before children in the array).
    let sorted = topologicallySorted(testSuites)

    let testSuiteJSON: [[String: Any]] = sorted.map { entry in
        var dict: [String: Any] = ["tier": entry.tier, "script": entry.script]
        if !entry.dependsOn.isEmpty {
            dict["dependsOn"] = entry.dependsOn
        }
        if entry.points > 1 {
            dict["points"] = entry.points
        }
        return dict
    }
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "gradingMode": gradingMode,
        "requiredFiles": [],
        "testSuites": testSuiteJSON,
        "timeLimitSeconds": 10,
        "makefile": includeMakefile ? ["target": NSNull()] : NSNull()
    ]
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
    solutionNotebookData: Data
) async throws -> String {
    let submissionsDir = req.application.submissionsDirectory
    let subID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
    let filePath = submissionsDir + "\(subID).ipynb"
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
        filename:      "solution.ipynb",
        userID:        user.id,
        kind:          APISubmission.Kind.validation
    )
    try await submission.save(on: req.db)
    return subID
}

func waitForRunnerValidation(
    req: Request,
    submissionID: String,
    timeoutSeconds: TimeInterval = 45
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
