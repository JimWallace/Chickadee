// APIServer/Services/DatasetsEditError.swift
//
// Why `applyDatasetsEdit` refused a change to an assignment's dataset specs.
// Each description is user-facing. The web `PUT /datasets` routes show it as a
// 400, and MCP `set_dataset` shows it as invalid arguments (#2771).

enum DatasetsEditError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A spec that `datasetSpecRefusal` or `DatasetSpecValidation` refused,
    /// with the reason it gave.
    case specRefused(String)
    /// The array names one file more than once.
    case duplicateFile(String)
    /// The change drops the spec of a file attached from the course library.
    case attachedSpecDropped(String)
    /// The change gives personal data to an activity that ranks or matches
    /// students (`ManifestCoherence`).
    case incoherent(String)

    var description: String {
        switch self {
        case .specRefused(let reason), .incoherent(let reason):
            return reason
        case .duplicateFile(let file):
            return "Dataset file '\(file)' is listed more than once."
        case .attachedSpecDropped(let file):
            return "'\(file)' is attached from the course library. Detach it to remove its dataset settings."
        }
    }
}
