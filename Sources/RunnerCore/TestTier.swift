// RunnerCore/TestTier.swift

/// Controls visibility of test results to students.
///
/// The case is named `pub` (not `public`) because `public` is a Swift keyword.
/// The JSON raw value is "public" to match the runner protocol.
public enum TestTier: String, Sendable {
    case pub = "public"  // results shown to student immediately
    case release = "release"  // run on demand, hidden until deadline
    case secret = "secret"  // never shown to student
}

// Codable is unavailable in Embedded Swift; only native targets serialize this.
#if !hasFeature(Embedded)
extension TestTier: Codable {}
#endif
