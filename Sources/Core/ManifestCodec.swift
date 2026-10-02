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
/// There is deliberately no plain `JSONEncoder` here. A plain encoder's
/// key order is not contractual: it was measured emitting two different
/// orderings for two equal `TestProperties` values encoded back to back,
/// serially, in one process -- 40 of 40 pairs on one run and 0 of 40 on
/// the next. One used to live here beside `stableEncoder`, and
/// `testSetupCacheKey` was added hashing it, so the runner's on-disk
/// test-setup cache could not reliably hit -- the same job keyed two ways
/// -- with no failure anywhere to say so (#1526). The REST zip upload was
/// its last production caller (#1719). Every manifest that is stored or
/// hashed now goes through `stableEncoder`, and a plain encoder cannot be
/// reached for by mistake because it does not exist.
///
/// `JSONDecoder` and `JSONEncoder` are `Sendable` in current Foundation,
/// so sharing these instances across request handlers is safe as long
/// as they are not reconfigured after initialization (we never do).
/// The shared instances exist for allocation reuse on hot paths, not
/// for concurrency-safety reasons.
public enum ManifestCodec {
    public static let decoder = JSONDecoder()

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
