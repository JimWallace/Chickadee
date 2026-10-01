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
/// decoder and must not use this one.
///
/// **`encoder`'s output is not stable for equal input, so NOTHING may
/// hash or store it.**  It is a plain `JSONEncoder`: key order is not
/// contractual, and it was measured emitting two different orderings for
/// two equal `TestProperties` values encoded back to back, serially, in
/// one process -- 40 of 40 pairs on one run and 0 of 40 on the next.
/// Any path that hashes or stores a manifest uses `stableEncoder`, whose
/// sorted keys make equal values produce equal bytes.
///
/// That rule used to be written here as a note about two named renderers
/// rather than as a property of this encoder, and `testSetupCacheKey` was
/// added hashing the shared one.  The runner's on-disk test-setup cache
/// then could not reliably hit -- the same job keyed two ways -- with no
/// failure anywhere to say so (#1526).
///
/// `JSONDecoder` and `JSONEncoder` are `Sendable` in current Foundation,
/// so sharing these instances across request handlers is safe as long
/// as they are not reconfigured after initialization (we never do).
/// The shared instances exist for allocation reuse on hot paths, not
/// for concurrency-safety reasons.
public enum ManifestCodec {
    public static let decoder = JSONDecoder()
    public static let encoder = JSONEncoder()

    /// The one encoder for a manifest that is STORED or HASHED: the
    /// `test_setups.manifest` column, a version snapshot, the runner's
    /// setup-cache key.  Sorted keys make equal values produce equal bytes,
    /// so a stored manifest changes only when its content does.
    public static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
