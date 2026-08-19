// RunnerCore/TestTier.swift

/// Controls visibility of test results to students.
///
/// The case is named `pub` (not `public`) because `public` is a Swift keyword.
/// The JSON raw value is "public" to match the runner protocol.
/// `CaseIterable` so the agent-facing tier prose can be DERIVED rather than
/// hand-typed. It was hand-typed, and it went stale in the way hand-typed lists
/// do: nine MCP strings advertised a fourth tier, `student`, that this enum has
/// never had — so `author_script` accepted it into its JSON schema and then
/// rejected it at `TestTier(rawValue:)`, while the web suite editor coerced it
/// to `.pub`. See `MCPTierProse`.
public enum TestTier: String, Sendable, CaseIterable {
    case pub = "public"  // results shown to student immediately
    case release = "release"  // run on demand, hidden until deadline
    case secret = "secret"  // never shown to student
}

// Codable is unavailable in Embedded Swift; only native targets serialize this.
#if !hasFeature(Embedded)
extension TestTier: Codable {}
#endif
