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
/// - `perPart`: a partition with no transforms. Each part is the same for
///   every student dealt it, so each part is stored once and the working copy
///   links to the student's part.
/// - `perStudent`: the bytes depend on the student (a sample or a transform),
///   so the working copy holds a file of its own.
public enum DatasetDeliveryMode: String, Codable, Sendable, Equatable, CaseIterable {
    case shared
    case perPart
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
    ///
    /// `perPart` needs a partition with a usable part count and no
    /// transforms. A transform varies the cells per student, so a transformed
    /// partition is `perStudent`; so is a partition with no part count, which
    /// authoring refuses and which the materializer would deliver whole.
    ///
    /// A spec whose capabilities select nothing is `shared` whatever the
    /// other settings say, because the materializer delivers it whole
    /// (docs/fhir-datasets-plan.md §11, decision 1). That is the safe
    /// direction too: the bytes really are the same for everyone.
    public init(
        capabilities: DatasetCapabilities, isPartition: Bool, partCount: Int?, sampleSize: Int?,
        hasTransforms: Bool
    ) {
        if !capabilities.selects {
            self = .shared
        } else if isPartition {
            self = !hasTransforms && (partCount ?? 0) > 0 ? .perPart : .perStudent
        } else {
            self = sampleSize == nil && !hasTransforms ? .shared : .perStudent
        }
    }
}

extension DatasetSpec {
    /// How this file is stored in a student's working copy.
    public var deliveryMode: DatasetDeliveryMode {
        DatasetDeliveryMode(
            capabilities: capabilities, isPartition: kind == .partition, partCount: partCount, sampleSize: sampleSize,
            hasTransforms: !transforms.isEmpty)
    }
}
