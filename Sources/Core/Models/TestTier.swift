// Core/Models/TestTier.swift

/// Controls visibility of test results to students.
///
/// The case is named `pub` (not `public`) because `public` is a Swift keyword.
/// The JSON raw value is "public" to match the runner protocol.
enum TestTier: String, Codable, Sendable {
    case pub     = "public"   // results shown to student immediately
    case release = "release"  // run on demand, hidden until deadline
    case secret  = "secret"   // never shown to student
    case student = "student"  // student-written tests, run for their benefit
}
