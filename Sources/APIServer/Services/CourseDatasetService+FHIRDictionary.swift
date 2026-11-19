// APIServer/Services/CourseDatasetService+FHIRDictionary.swift
//
// The FHIR data dictionary of a library version (docs/fhir-datasets-plan.md
// §5): the prose of each resource type and each code, and the example
// resource. The CSV dictionary is `updateDictionary`; a FHIR version has no
// columns, so it edits its summary instead.

import Core
import Fluent
import Foundation

extension CourseDatasetService {

    /// One edit of a FHIR dictionary. A nil `example` keeps the current one.
    struct FHIRDictionaryEdit: Sendable {
        var types: [(resourceType: String, description: String)] = []
        var codes: [(key: FHIRDatasetSummary.CodeKey, description: String)] = []
        /// True when the edit names every entry, as the page form does, so
        /// an entry it leaves out loses its prose. False for an agent that
        /// edits one entry.
        var replacingOthers: Bool
        var example: (resourceType: String, id: String)?
    }

    /// Applies `edit` to the dictionary of version `number` of a FHIR dataset.
    static func updateFHIRDictionary(
        _ dataset: APICourseDataset, version number: Int, edit: FHIRDictionaryEdit,
        blobs: AssignmentVersionBlobStore, on db: any Database
    ) async throws -> APICourseDatasetVersion {
        switch dataset.format {
        case .fhirNdjson: break
        case .csv:
            throw CourseDatasetError.dictionary("'\(dataset.slug)' is a CSV dataset. Describe its columns instead.")
        }
        guard let version = try await version(number, of: dataset, on: db) else {
            throw CourseDatasetError.unknownVersion(number)
        }
        guard let summary = version.summary else {
            throw CourseDatasetError.dictionary("Version \(number) of \(dataset.slug) has no summary.")
        }
        do {
            var edited = try summary.withNotes(
                types: edit.types, codes: edit.codes, replacingOthers: edit.replacingOthers)
            if let pick = edit.example {
                guard let text = String(bytes: try bytes(of: version, blobs: blobs), encoding: .utf8) else {
                    throw CourseDatasetError.dictionary("The file of version \(number) could not be read.")
                }
                edited = try edited.withExample(resourceType: pick.resourceType, id: pick.id, in: text)
            }
            version.summary = edited
        } catch let issue as FHIRDictionaryEditIssue {
            throw CourseDatasetError.dictionary(issue.description)
        }
        try await version.update(on: db)
        return version
    }
}
