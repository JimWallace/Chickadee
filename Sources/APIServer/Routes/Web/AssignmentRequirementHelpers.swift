// APIServer/Routes/Web/AssignmentRequirementHelpers.swift
//
// Build, persist, and infer `AssignmentRequirementSpec` values from
// instructor-supplied CSVs and from scanning the assignment + solution
// notebooks plus zip contents.  Extracted from AssignmentHelpers.swift
// (issue #442) — no behaviour changes.

import Vapor
import Fluent
import Core
import Foundation

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
