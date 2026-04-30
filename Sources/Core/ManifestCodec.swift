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
/// `nonisolated(unsafe)`: `JSONDecoder` and `JSONEncoder` are not
/// `Sendable` in current Swift Foundation, but their thread-safety
/// contract permits concurrent `decode` / `encode` calls as long as the
/// instance is not reconfigured.  These two are configured once at
/// startup with default settings and never mutated, so concurrent use
/// from request handlers is safe.
public enum ManifestCodec {
    nonisolated(unsafe) public static let decoder: JSONDecoder = JSONDecoder()
    nonisolated(unsafe) public static let encoder: JSONEncoder = JSONEncoder()
}
