// Core/FHIRNdjsonProfile.swift
//
// The structural check of a FHIR NDJSON dataset file, and the summary that
// the Data page shows (docs/fhir-datasets-plan.md §3 and §5).
//
// Structure only, on purpose: each line is a JSON object with a string
// `resourceType` and a string `id`, and no type/id pair repeats. Validating
// against FHIR profiles needs the specification package and a validator that
// Swift does not have (§3, F2).
//
// The file is parsed only to check it and to count it. Nothing here writes a
// line back: delivery copies the file's own bytes, so a student reads exactly
// what the instructor uploaded.

import Foundation

/// Checks a FHIR NDJSON file and summarizes what it holds.
public enum FHIRNdjsonProfile {

    /// Checks `text` and returns its summary, or throws the first problem
    /// found, in line order. Blank lines are skipped; `\r\n` and `\r` read
    /// as `\n`, as for a CSV dataset.
    public static func profile(_ text: String) throws(FHIRDatasetIssue) -> FHIRDatasetSummary {
        var tally = Tally()
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (offset, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            try tally.add(resource(in: line, lineNumber: offset + 1), line: line, lineNumber: offset + 1)
        }
        guard tally.resourceCount > 0 else { throw .empty }
        return tally.summary()
    }

    /// The line of `text` that holds the resource `resourceType`/`id`, as
    /// an example, or nil when the file has none or the line is longer than
    /// `FHIRDatasetSummary.maxExampleBytes`.
    public static func example(
        resourceType: String, id: String, in text: String
    ) -> FHIRDatasetSummary.ExampleResource? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A cheap test first: the id must appear on the line.
            guard line.contains(id),
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                object["resourceType"] as? String == resourceType, object["id"] as? String == id
            else { continue }
            guard line.utf8.count <= FHIRDatasetSummary.maxExampleBytes else { return nil }
            return .init(resourceType: resourceType, id: id, json: line)
        }
        return nil
    }

    /// The JSON object on one line, checked for a type and an id.
    private static func resource(in line: String, lineNumber: Int) throws(FHIRDatasetIssue) -> Resource {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw .notAnObject(line: lineNumber)
        }
        guard let resourceType = object["resourceType"] as? String, !resourceType.isEmpty else {
            throw .missingResourceType(line: lineNumber)
        }
        guard let id = object["id"] as? String, !id.isEmpty else {
            throw .missingID(line: lineNumber, resourceType: resourceType)
        }
        return Resource(
            type: resourceType, id: id, patientReferences: patientReferences(in: object),
            codings: codings(in: object), unit: quantityUnit(in: object))
    }

    /// The `Patient/<id>` ids named by the resource's top-level `subject` or
    /// `patient` reference.
    private static func patientReferences(in object: [String: Any]) -> [String] {
        ["subject", "patient"].compactMap { key in
            guard let reference = (object[key] as? [String: Any])?["reference"] as? String,
                reference.hasPrefix("Patient/")
            else { return nil }
            let id = String(reference.dropFirst("Patient/".count))
            return id.isEmpty ? nil : id
        }
    }

    /// The codings of the resource's top-level `code` CodeableConcept.
    private static func codings(in object: [String: Any]) -> [Coding] {
        guard let concept = object["code"] as? [String: Any], let codings = concept["coding"] as? [Any] else {
            return []
        }
        return codings.compactMap { entry in
            guard let coding = entry as? [String: Any], let code = coding["code"] as? String, !code.isEmpty else {
                return nil
            }
            // An empty system reads as none, so a page can send it back as "".
            let system = (coding["system"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Coding(system: system, code: code, display: coding["display"] as? String)
        }
    }

    /// The resource's `valueQuantity.unit`, or nil.
    private static func quantityUnit(in object: [String: Any]) -> String? {
        guard let unit = (object["valueQuantity"] as? [String: Any])?["unit"] as? String, !unit.isEmpty else {
            return nil
        }
        return unit
    }

    private struct Coding: Hashable {
        let system: String?
        let code: String
        let display: String?
    }

    private struct Resource {
        let type: String
        let id: String
        let patientReferences: [String]
        let codings: [Coding]
        let unit: String?
    }

    private struct CodeKey: Hashable {
        let resourceType: String
        let system: String?
        let code: String
    }

    private struct CodeTally {
        var display: String?
        var count = 0
        var units: Set<String> = []
    }

    /// The running counts over the file.
    private struct Tally {
        var resourceCount = 0
        var firstLine: [String: Int] = [:]
        var typeCounts: [String: Int] = [:]
        var patientIDs: Set<String> = []
        var referencedPatientIDs: [String] = []
        var codes: [CodeKey: CodeTally] = [:]
        /// The default example: the first Observation, else the first
        /// resource, that fits `maxExampleBytes`.
        var firstObservation: FHIRDatasetSummary.ExampleResource?
        var firstResource: FHIRDatasetSummary.ExampleResource?

        mutating func add(_ resource: Resource, line: String, lineNumber: Int) throws(FHIRDatasetIssue) {
            let key = resource.type + "/" + resource.id
            if let first = firstLine[key] {
                throw .duplicateResource(
                    resourceType: resource.type, id: resource.id, line: lineNumber, firstLine: first)
            }
            firstLine[key] = lineNumber
            resourceCount += 1
            typeCounts[resource.type, default: 0] += 1
            if resource.type == "Patient" { patientIDs.insert(resource.id) }
            if line.utf8.count <= FHIRDatasetSummary.maxExampleBytes {
                let example = FHIRDatasetSummary.ExampleResource(
                    resourceType: resource.type, id: resource.id, json: line)
                if firstResource == nil { firstResource = example }
                if firstObservation == nil, resource.type == "Observation" { firstObservation = example }
            }
            referencedPatientIDs.append(contentsOf: resource.patientReferences)
            // A resource that carries one code twice counts once.
            for coding in Set(resource.codings) {
                let codeKey = CodeKey(resourceType: resource.type, system: coding.system, code: coding.code)
                var entry = codes[codeKey] ?? CodeTally()
                entry.display = entry.display ?? coding.display
                entry.count += 1
                if let unit = resource.unit { entry.units.insert(unit) }
                codes[codeKey] = entry
            }
        }

        func summary() -> FHIRDatasetSummary {
            let uses = codes.map { key, tally in
                FHIRDatasetSummary.CodeUse(
                    resourceType: key.resourceType, system: key.system, code: key.code, display: tally.display,
                    count: tally.count, units: tally.units.sorted())
            }
            .sorted(by: Self.codeOrder)
            return FHIRDatasetSummary(
                fhirVersion: FHIRDatasetSummary.readAsVersion, resourceCount: resourceCount,
                patientCount: typeCounts["Patient"] ?? 0,
                resourceTypes: typeCounts.sorted { $0.key < $1.key }.map {
                    FHIRDatasetSummary.TypeCount(resourceType: $0.key, count: $0.value)
                },
                codes: Array(uses.prefix(FHIRDatasetSummary.maxListedCodes)),
                omittedCodeCount: max(uses.count - FHIRDatasetSummary.maxListedCodes, 0),
                danglingPatientReferences: referencedPatientIDs.count { !patientIDs.contains($0) },
                example: firstObservation ?? firstResource)
        }

        /// Most used first; ties by type, system and code, so the order never
        /// depends on dictionary iteration.
        static func codeOrder(_ lhs: FHIRDatasetSummary.CodeUse, _ rhs: FHIRDatasetSummary.CodeUse) -> Bool {
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.resourceType != rhs.resourceType { return lhs.resourceType < rhs.resourceType }
            if lhs.system != rhs.system { return (lhs.system ?? "") < (rhs.system ?? "") }
            return lhs.code < rhs.code
        }
    }
}
