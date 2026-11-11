// Core/FHIRDatasetSummary+Dictionary.swift
//
// The FHIR data dictionary (docs/fhir-datasets-plan.md §5): the prose an
// instructor writes for each resource type and each code of a FHIR dataset,
// and the example resource the Data page shows. The CSV counterpart is
// `DatasetDictionary`, which keys prose on the column name; this keys it on
// the resource type, or on the (type, system, code) of a code.
//
// Prose lives on the summary's own entries, so it can only name an entry the
// file has. An edit that names another is refused, as a CSV edit that names a
// column the header lacks is refused (D7).

import Foundation

extension FHIRDatasetSummary {

    /// The name of a code in a message: "Observation 8310-5 (LOINC)".
    static func entryName(_ key: CodeKey) -> String {
        let system = key.system.map { " (\(CodeUse.name(ofSystem: $0)))" } ?? ""
        return "\(key.resourceType) \(key.code)\(system)"
    }

    /// This summary with the prose in `types` (by resource type) and `codes`.
    /// An entry the lists do not name keeps its prose when `replacingOthers`
    /// is false (an agent that edits one entry) and loses it when true (the
    /// page form, which posts every entry). Blank text clears an entry. An
    /// entry the file lacks, one named twice, or a description longer than
    /// `maxDescriptionCharacters` is refused.
    public func withNotes(
        types: [(resourceType: String, description: String)], codes: [(key: CodeKey, description: String)],
        replacingOthers: Bool
    ) throws(FHIRDictionaryEditIssue) -> FHIRDatasetSummary {
        let knownTypes = Set(resourceTypes.map(\.resourceType))
        var typeProse: [String: String?] = [:]
        for entry in types {
            guard knownTypes.contains(entry.resourceType) else { throw .unknownResourceType(entry.resourceType) }
            guard typeProse[entry.resourceType] == nil else { throw .describedTwice(entry.resourceType) }
            guard entry.description.count <= Self.maxDescriptionCharacters else { throw .tooLong(entry.resourceType) }
            typeProse[entry.resourceType] = .some(DatasetDictionary.cleaned(entry.description))
        }
        let knownCodes = Set(self.codes.map(\.key))
        var codeProse: [CodeKey: String?] = [:]
        for entry in codes {
            guard knownCodes.contains(entry.key) else { throw .unknownCode(entry.key) }
            guard codeProse[entry.key] == nil else { throw .describedTwice(Self.entryName(entry.key)) }
            guard entry.description.count <= Self.maxDescriptionCharacters else {
                throw .tooLong(Self.entryName(entry.key))
            }
            codeProse[entry.key] = .some(DatasetDictionary.cleaned(entry.description))
        }
        var edited = self
        edited.resourceTypes = resourceTypes.map { entry in
            var entry = entry
            if let text = typeProse[entry.resourceType] {
                entry.description = text
            } else if replacingOthers {
                entry.description = nil
            }
            return entry
        }
        edited.codes = self.codes.map { entry in
            var entry = entry
            if let text = codeProse[entry.key] {
                entry.description = text
            } else if replacingOthers {
                entry.description = nil
            }
            return entry
        }
        return edited
    }

    /// This summary with the resource `resourceType`/`id` of `text` as its
    /// example. `text` is the version's file.
    public func withExample(
        resourceType: String, id: String, in text: String
    ) throws(FHIRDictionaryEditIssue) -> FHIRDatasetSummary {
        guard let example = FHIRNdjsonProfile.example(resourceType: resourceType, id: id, in: text) else {
            throw .unknownExample(resourceType: resourceType, id: id)
        }
        var edited = self
        edited.example = example
        return edited
    }

    /// This summary, computed from a new file `text`, with the prose of
    /// `previous` on every entry this file still has, and `previous`'s
    /// example when this file still has that resource. Otherwise the example
    /// stays this summary's default.
    public func carryingNotes(from previous: FHIRDatasetSummary, text: String) -> FHIRDatasetSummary {
        // A description over the cap, which only a hand-made bundle can
        // carry, is dropped rather than refusing the file.
        let fits = { (text: String) in text.count <= Self.maxDescriptionCharacters }
        let typeProse = Dictionary(
            previous.resourceTypes.compactMap { entry in
                entry.description.flatMap { fits($0) ? (entry.resourceType, $0) : nil }
            },
            uniquingKeysWith: { first, _ in first })
        let codeProse = Dictionary(
            previous.codes.compactMap { entry in entry.description.flatMap { fits($0) ? (entry.key, $0) : nil } },
            uniquingKeysWith: { first, _ in first })
        var carried = self
        carried.resourceTypes = resourceTypes.map { entry in
            var entry = entry
            entry.description = typeProse[entry.resourceType]
            return entry
        }
        carried.codes = codes.map { entry in
            var entry = entry
            entry.description = codeProse[entry.key]
            return entry
        }
        if let pick = previous.example,
            let example = FHIRNdjsonProfile.example(resourceType: pick.resourceType, id: pick.id, in: text)
        {
            carried.example = example
        }
        return carried
    }

    /// One code system's codes, as the pages group them.
    public struct CodeGroup: Equatable, Sendable {
        /// The system's name for a student (`CodeUse.systemName`), or "No
        /// system".
        public let name: String
        public let codes: [CodeUse]
    }

    /// The codes grouped by system name, each group in the order its system
    /// first appears in `codes` (most used first).
    public var codeGroups: [CodeGroup] {
        var order: [String] = []
        var byName: [String: [CodeUse]] = [:]
        for entry in codes {
            let name = entry.systemName ?? "No system"
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(entry)
        }
        return order.map { CodeGroup(name: $0, codes: byName[$0] ?? []) }
    }

    /// The example laid out one member per line for the Data page, or the
    /// line itself when the re-indenter cannot read it.
    public var exampleText: String? {
        example.map { JSONReindenter.reindent($0.json) ?? $0.json }
    }
}
