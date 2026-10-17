// APIServer/Routes/Web/InstructorSuiteOutlineBuilder.swift
//
// Builds the instructor's suite outline (`InstructorSuiteOutline`) from the
// manifest, the notebook that decides the anchors, and the last validation
// run on the solution. Pure, so the tests build it from fixed inputs; the
// route only gathers them.

import Core
import Foundation

struct InstructorSuiteOutlineBuilder {
    let manifest: TestProperties
    /// The solution's definitions (or the starter's, when there is no
    /// solution yet), which decide each item's anchor.
    let notebook: NotebookDefinitionScan
    /// The source of each hand-written script, by filename.
    let scriptSources: [String: String]
    /// The assignment's `validationStatus`.
    let validationStatus: String?
    /// The last validation run on the solution, or nil before one.
    let solutionRun: TestOutcomeCollection?

    func build() -> InstructorSuiteOutline {
        let outcomes = outcomesByScript()
        var sections: [InstructorSuiteOutline.Section] = []
        var unlinked: [InstructorSuiteOutline.Item] = []
        for (sectionID, title) in groups() {
            let entries = manifest.testSuites.filter { sectionOf($0) == sectionID }
            guard !entries.isEmpty || sectionID != nil else { continue }
            var items: [InstructorSuiteOutline.Item] = []
            for entry in entries {
                let item = self.item(for: entry, outcome: outcomes[entry.script])
                if item.anchor == nil {
                    unlinked.append(item)
                } else {
                    items.append(item)
                }
            }
            let (label, _) = NotebookGuideBuilder.splitHeading(title)
            sections.append(
                InstructorSuiteOutline.Section(
                    id: sectionID, title: title, label: label,
                    points: entries.reduce(0) { $0 + $1.points }, items: items))
        }
        let all = sections.flatMap(\.items) + unlinked
        let issues = all.compactMap { item -> InstructorSuiteOutline.Issue? in
            guard let result = item.solution?.result, result != TestStatus.pass.rawValue else { return nil }
            return InstructorSuiteOutline.Issue(itemID: item.id, kind: "failsOnSolution")
        }
        return InstructorSuiteOutline(
            version: InstructorSuiteOutline.currentVersion,
            validation: .init(status: validationStatus, solutionRunAt: solutionRun?.timestamp, issues: issues),
            totals: .init(checks: manifest.testSuites.count, points: manifest.testSuites.reduce(0) { $0 + $1.points }),
            sections: sections,
            unlinked: unlinked)
    }

    // MARK: - Groups

    /// Each suite section in order, then the items in no section when any.
    private func groups() -> [(id: String?, title: String?)] {
        var groups: [(String?, String?)] = manifest.sections.map { ($0.id, $0.name) }
        if manifest.testSuites.contains(where: { sectionOf($0) == nil }) {
            groups.append((nil, nil))
        }
        return groups
    }

    /// The entry's section, or nil when it has none or names one that no
    /// longer exists.
    private func sectionOf(_ entry: TestSuiteEntry) -> String? {
        guard let id = entry.sectionID, manifest.sections.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // MARK: - Items

    private func item(for entry: TestSuiteEntry, outcome: TestOutcome?) -> InstructorSuiteOutline.Item {
        let stem = runnerScriptStem(entry.script)
        let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return InstructorSuiteOutline.Item(
            id: entry.script,
            name: displayName ?? (stem.isEmpty ? entry.script : stem),
            kind: entry.generatedByCheck != nil ? "check" : entry.generatedBy != nil ? "family" : "script",
            checkKind: checkKind(of: entry),
            tier: entry.tier.rawValue,
            points: entry.points,
            anchor: anchor(for: entry),
            solution: outcome.map(runResult))
    }

    private func checkKind(of entry: TestSuiteEntry) -> String? {
        if let id = entry.generatedByCheck {
            return manifest.notebookChecks.first { $0.id == id }?.kind.rawValue
        }
        if let id = entry.generatedBy {
            return manifest.patternFamilies.first { $0.id == id }?.kind.rawValue
        }
        return nil
    }

    private func anchor(for entry: TestSuiteEntry) -> InstructorSuiteOutline.Anchor? {
        let request = NotebookTestAnchoring.request(
            for: entry, in: manifest, scriptSource: scriptSources[entry.script])
        let resolved = NotebookTestAnchoring.resolve(request, solution: notebook)
        guard let name = resolved.name else { return nil }
        let kind: String
        switch resolved.kind {
        case .name: kind = notebook.definition(of: name)?.kind.rawValue ?? "name"
        case .section: kind = "section"
        case .unlinked: return nil
        }
        return InstructorSuiteOutline.Anchor(kind: kind, name: name, source: "auto", ambiguous: resolved.ambiguous)
    }

    private func runResult(_ outcome: TestOutcome) -> InstructorSuiteOutline.RunResult {
        guard outcome.status != .pass else { return .init(result: outcome.status.rawValue) }
        let short = formattedShortResult(from: outcome.shortResult, status: outcome.status)
        return .init(result: outcome.status.rawValue, detail: short.isEmpty ? nil : short)
    }

    /// The run's outcomes, by script filename. The worker names an outcome by
    /// the script's stem and the browser by its filename, so both are matched.
    private func outcomesByScript() -> [String: TestOutcome] {
        guard let solutionRun else { return [:] }
        let byName = Dictionary(
            solutionRun.outcomes.map { ($0.testName, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: TestOutcome] = [:]
        for entry in manifest.testSuites {
            result[entry.script] = byName[entry.script] ?? byName[runnerScriptStem(entry.script)]
        }
        return result
    }
}
