// APIServer/Routes/Web/SuiteRowHelpers.swift
//
// The row builders that feed the editor view (`editableSuiteRowsForSetup`,
// `familySuiteRowsForSetup`, `currentSetupFiles`) and the publish-time
// authored-item reconstruction (`authoredSuiteItemsFromDraftManifest`).
// Extracted from AssignmentHelpers.swift (issue #442) — no behaviour
// changes. The suite-config types and builders that services also use moved
// to `Helpers/SuiteConfigBuilding.swift` (#1726).

import Core
import Foundation
import Vapor

// MARK: - Editor view row builders

func currentSetupFiles(
    for setup: APITestSetup, assignmentID: String, solutionFilename: String?
) async -> (
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

    let archiveFiles = await listZipEntries(zipPath: setup.zipPath)
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

    // Per-student dataset marks, from the one lookup `get_support_files` reads
    // (`TestProperties.datasetSpecsByFile`) so the Files panel and the MCP
    // listing cannot report different states for the same file.
    let datasetSpecs = setup.decodedManifest()?.datasetSpecsByFile ?? [:]

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
            displayName: entry?.name,
            isDataset: datasetSpecs[name] != nil,
            datasetSampleSize: datasetSpecs[name]?.sampleSize,
            datasetStratumColumn: datasetSpecs[name]?.stratumColumn,
            datasetTransforms: datasetSpecs[name]?.transforms ?? []
        )
    }

    return (assignmentFile, solutionFile, existingSuiteRows)
}

func editableSuiteRowsForSetup(_ setup: APITestSetup) async -> [EditableSuiteRow] {
    let entries = await listZipEntries(zipPath: setup.zipPath)
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

    // Same one lookup as `currentSetupFiles` above, so the create page's Files
    // panel reports what the edit page's does for the same manifest.
    let datasetSpecs = setup.decodedManifest()?.datasetSpecsByFile ?? [:]

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
            displayName: info?.name,
            isDataset: datasetSpecs[name] != nil,
            datasetSampleSize: datasetSpecs[name]?.sampleSize,
            datasetStratumColumn: datasetSpecs[name]?.stratumColumn,
            datasetTransforms: datasetSpecs[name]?.transforms ?? []
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
                        // round-trip via SuiteConfigRow).
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
