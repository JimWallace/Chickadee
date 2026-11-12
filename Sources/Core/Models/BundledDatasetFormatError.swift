// Core/Models/BundledDatasetFormatError.swift
//
// A bundled dataset of a format this server does not know
// (docs/dataset-kinds-plan.md §5). Bundle schemaVersion 3 means "datasets
// carry a format", so a later format needs no new version: a reader that does
// not know one refuses it by name, with this error.

/// Why a bundled dataset cannot be imported here.
public enum BundledDatasetFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownFormat(slug: String, format: String)

    public var description: String {
        switch self {
        case .unknownFormat(let slug, let format):
            return "The dataset '\(slug)' has the format '\(format)', which this server does not know. Import "
                + "the bundle into the server that exported it, or a newer one."
        }
    }
}
