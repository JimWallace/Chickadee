// APIServer/Routes/Web/NotebookGuideBuilder.swift
//
// Builds the student guide (`NotebookGuide`) from values the route has
// already read: the manifest, the solution and starter notebooks, the scripts
// and the latest attempt. Pure, so the tests drive it with no database.
//
// The rules that keep it safe to send to a student:
// - Only public checks are listed and only they set a task's status. Every
//   other test is a count.
// - A check's `detail` is its failure text after its failure-detail setting,
//   as the results page shows it. Its `hint` is the hint the results page
//   shows. Neither is sent for a pass.

import Core
import Foundation

struct NotebookGuideBuilder {
    /// The latest student submission and what grading made of it.
    struct AttemptInput {
        var submissionID: String
        var number: Int
        /// Nil while the submission is still being graded.
        var collection: TestOutcomeCollection?
    }

    let manifest: TestProperties
    /// The solution's definitions, which decide a script test's anchor.
    let solution: NotebookDefinitionScan
    /// This student's personalized starter notebook, or nil when the
    /// assignment has none.
    let starter: Data?
    /// The source of each hand-written script, by filename. A missing script
    /// anchors by its section.
    let scriptSources: [String: String]
    let attempt: AttemptInput?

    func build() -> NotebookGuide {
        let language = AssignmentLanguage.resolve(manifest: manifest)
        let starterScan = starter.map { scanNotebookDefinitions($0, language: language) }
        let outcomes = outcomesByScript()
        let hints = buildHintByFilename(manifest)
        let failureDetails = buildFailureDetailByFilename(manifest)

        var tasks: [NotebookGuide.Task] = []
        var anchorsForStarter: [NotebookGuide.Anchor] = []
        for (sectionID, heading) in taskGroups() {
            let entries = manifest.testSuites.filter { taskSectionID(of: $0) == sectionID }
            guard !entries.isEmpty || sectionID != nil else { continue }
            let publicEntries = entries.filter { $0.tier == .pub }
            // Public tests only: a hidden test's target is not the student's
            // to read. A task with no public test points at its heading.
            let anchors = taskAnchors(for: publicEntries, heading: heading)
            anchorsForStarter += anchors
            let checks = publicEntries.map { entry in
                check(for: entry, outcome: outcomes[entry.script], hints: hints, failureDetails: failureDetails)
            }
            let (label, name) = Self.splitHeading(heading)
            tasks.append(
                NotebookGuide.Task(
                    sectionID: sectionID,
                    heading: heading,
                    label: label,
                    name: name,
                    points: entries.reduce(0) { $0 + $1.points },
                    anchors: anchors,
                    status: status(of: checks),
                    checks: checks,
                    hiddenCount: entries.count - publicEntries.count))
        }

        return NotebookGuide(
            version: NotebookGuide.currentVersion,
            language: language?.rawValue,
            attempt: attemptPayload(),
            tasks: tasks,
            starterSources: starterScan.map { starterSources(for: anchorsForStarter, in: $0) } ?? [:],
            reflections: reflections())
    }

    // MARK: - Tasks

    /// Each suite section in order, then the checks in no section when there
    /// are any.
    private func taskGroups() -> [(sectionID: String?, heading: String?)] {
        var groups: [(String?, String?)] = manifest.sections.map { ($0.id, $0.name) }
        if manifest.testSuites.contains(where: { taskSectionID(of: $0) == nil }) {
            groups.append((nil, nil))
        }
        return groups
    }

    /// The entry's section, or nil when it has none or names one that no
    /// longer exists. Such an entry joins the last task.
    private func taskSectionID(of entry: TestSuiteEntry) -> String? {
        guard let id = entry.sectionID, manifest.sections.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func taskAnchors(for entries: [TestSuiteEntry], heading: String?) -> [NotebookGuide.Anchor] {
        var seen: Set<String> = []
        var anchors: [NotebookGuide.Anchor] = []
        for entry in entries {
            let request = NotebookTestAnchoring.request(
                for: entry, in: manifest, scriptSource: scriptSources[entry.script])
            let anchor = NotebookTestAnchoring.resolve(request, solution: solution)
            guard let name = anchor.name else { continue }
            let kind: String
            switch anchor.kind {
            // `name` when the solution does not define it (a pinned name, or
            // a check written before the code): its kind is unknown.
            case .name: kind = solution.definition(of: name)?.kind.rawValue ?? "name"
            case .section: kind = "section"
            case .unlinked: continue
            }
            guard seen.insert("\(kind):\(name)").inserted else { continue }
            anchors.append(NotebookGuide.Anchor(kind: kind, name: name, ambiguous: anchor.ambiguous ? true : nil))
        }
        if anchors.isEmpty, let heading, solution.sections.contains(where: { $0.name == heading }) {
            anchors.append(NotebookGuide.Anchor(kind: "section", name: heading))
        }
        return anchors
    }

    private func check(
        for entry: TestSuiteEntry, outcome: TestOutcome?,
        hints: [String: String], failureDetails: [String: FailureDetail]
    ) -> NotebookGuide.Check {
        let stem = runnerScriptStem(entry.script)
        let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var check = NotebookGuide.Check(
            name: displayName ?? (stem.isEmpty ? entry.script : stem),
            kind: entry.generatedByCheck != nil ? "check" : entry.generatedBy != nil ? "family" : "script",
            result: outcome?.status.rawValue)
        guard let outcome, outcome.status != .pass, !parseSkip(shortResult: outcome.shortResult).isSkipped else {
            return check
        }
        var short = formattedShortResult(from: outcome.shortResult, status: outcome.status)
        if let detail = failureDetails[entry.script], detail != .full {
            short =
                maskFailureOutput(shortResult: short, longResult: nil, status: outcome.status, detail: detail)
                .shortResult
        }
        check.detail = short
        check.hint = hints[entry.script]
        return check
    }

    private func status(of checks: [NotebookGuide.Check]) -> String? {
        guard let attempt else { return "fresh" }
        guard attempt.collection != nil else { return nil }
        // A public check with no outcome (the suite changed after grading)
        // leaves the status unknown rather than claiming a pass.
        guard !checks.isEmpty, checks.allSatisfy({ $0.result != nil }) else { return nil }
        return checks.allSatisfy { $0.result == TestStatus.pass.rawValue } ? "pass" : "fail"
    }

    /// "Task 2: Average heart rate" → ("Task 2", "Average heart rate").
    static func splitHeading(_ heading: String?) -> (label: String?, name: String) {
        guard let heading else { return (nil, "Other checks") }
        guard let colon = heading.firstIndex(of: ":") else { return (nil, heading) }
        let label = heading[..<colon].trimmingCharacters(in: .whitespaces)
        let name = heading[heading.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !name.isEmpty else { return (nil, heading) }
        return (label, name)
    }

    // MARK: - Results

    /// The latest attempt's public outcomes, by script filename. The worker
    /// names an outcome by the script's stem and the browser by its filename,
    /// so both are matched.
    private func outcomesByScript() -> [String: TestOutcome] {
        guard let collection = attempt?.collection else { return [:] }
        let byName = Dictionary(
            collection.outcomes.filter { $0.tier == .pub }.map { ($0.testName, $0) },
            uniquingKeysWith: { first, _ in first })
        var result: [String: TestOutcome] = [:]
        for entry in manifest.testSuites where entry.tier == .pub {
            result[entry.script] = byName[entry.script] ?? byName[runnerScriptStem(entry.script)]
        }
        return result
    }

    private func attemptPayload() -> NotebookGuide.Attempt? {
        guard let attempt else { return nil }
        let url = "/submissions/\(attempt.submissionID)"
        guard let collection = attempt.collection else {
            return NotebookGuide.Attempt(number: attempt.number, pending: true, url: url)
        }
        return NotebookGuide.Attempt(
            number: attempt.number, pending: false,
            percent: gradePercent(from: collection),
            points: collection.earnedPoints,
            pointsPossible: collection.totalPoints,
            url: url)
    }

    // MARK: - Starter and reflections

    private func starterSources(
        for anchors: [NotebookGuide.Anchor], in scan: NotebookDefinitionScan
    ) -> [String: String] {
        guard let starter, let cells = NotebookCellView.cells(from: starter) else { return [:] }
        var sources: [String: String] = [:]
        for anchor in anchors {
            let isSection = anchor.kind == "section"
            let index =
                isSection ? scan.firstCodeCell(inSection: anchor.name) : scan.definition(of: anchor.name)?.cellIndex
            guard let index, cells.indices.contains(index) else { continue }
            let key = isSection ? "section:\(anchor.name)" : anchor.name
            sources[key] = Self.normalizedSource(cells[index].source)
        }
        return sources
    }

    /// CRLF to LF, and no trailing whitespace on a line or at the end.
    static func normalizedSource(_ source: String) -> String {
        var lines =
            source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func reflections() -> [NotebookGuide.Reflection] {
        guard let starter else { return [] }
        let pairs = ReflectionCells.pairs(starter: starter, submission: nil)
        return pairs.map { pair in
            NotebookGuide.Reflection(
                label: pairs.count == 1 ? "Reflection" : "Reflection \(pair.index)",
                tag: ReflectionCells.tag,
                readBy: "course staff")
        }
    }
}
