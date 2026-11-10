// Core/Models/DatasetDeliveryMode.swift
//
// Whether one stored copy of a dataset file can serve every student, or each
// student needs a copy of their own (docs/dataset-shared-delivery.md).
// `DatasetMaterializer` stays the one answer to what the bytes are; this only
// decides whether they can be stored once.

/// How a dataset file is stored in a student's editor working copy.
///
/// - `shared`: every student receives the source bytes unchanged, so the
///   working copy links to the setup's one extracted copy.
/// - `perStudent`: the bytes depend on the student (a sample, a part or a
///   transform), so the working copy holds a file of its own.
public enum DatasetDeliveryMode: String, Codable, Sendable, Equatable, CaseIterable {
    case shared
    case perStudent

    /// The mode for a spec with these settings. This is the one statement of
    /// the rule: `DatasetSpec.isShared` and `deliveryMode` read it, and so does
    /// the Files panel row, which holds the settings but not the spec.
    ///
    /// `shared` needs all three: no partition, no sample size, no transforms.
    /// A sample size at or above the row count also gives the whole file, but
    /// it still classifies as `perStudent`: the rule reads only the spec, and
    /// a wrong `perStudent` costs storage where a wrong `shared` would hand
    /// one student's rows to every student.
    public init(isPartition: Bool, sampleSize: Int?, hasTransforms: Bool) {
        self = !isPartition && sampleSize == nil && !hasTransforms ? .shared : .perStudent
    }
}

extension DatasetSpec {
    /// How this file is stored in a student's working copy.
    public var deliveryMode: DatasetDeliveryMode {
        DatasetDeliveryMode(isPartition: kind == .partition, sampleSize: sampleSize, hasTransforms: !transforms.isEmpty)
    }
}
