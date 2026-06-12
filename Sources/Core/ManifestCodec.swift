import Foundation

/// Shared `JSONDecoder` and `JSONEncoder` instances for `TestProperties`
/// (the instructor-authored manifest stored in `test.properties.json`).
///
/// Using these reused instances avoids per-request allocation on hot
/// request paths — every assignment edit, suite save, validate, and
/// student submission view decodes the manifest at least once, often
/// several times.
///
/// `TestProperties` and its members contain no `Date` fields, so the
/// default `JSONDecoder`/`JSONEncoder` configuration is sufficient.
/// Code paths that decode `Date`-bearing types (`TestOutcomeCollection`,
/// `WorkerExecutionReport`, `Job`) need their own iso8601-configured
/// decoder and must not use this one.  Code paths that hash a canonical
/// encoding (`PatternFamilyRenderer`, `NotebookCheckRenderer`) need
/// `outputFormatting = [.sortedKeys]` and also stay on a local encoder.
///
/// `JSONDecoder` and `JSONEncoder` are `Sendable` in current Foundation,
/// so sharing these instances across request handlers is safe as long
/// as they are not reconfigured after initialization (we never do).
/// The shared instances exist for allocation reuse on hot paths, not
/// for concurrency-safety reasons.
public enum ManifestCodec {
    public static let decoder = JSONDecoder()
    public static let encoder = JSONEncoder()
}
