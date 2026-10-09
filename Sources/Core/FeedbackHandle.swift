// Core/FeedbackHandle.swift
//
// The pseudonym an AI agent sees in place of a student
// (docs/ai-assisted-feedback.md §"Pseudonymous handles"). It is random, made
// once per (student, assignment) and stored, so it says nothing about the
// student and cannot link one student across two assignments.

/// A random feedback handle such as `R-7Q2M4K`.
public enum FeedbackHandle {
    /// Digits and capitals without the look-alikes 0/O, 1/I/L and U.
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let length = 6
    static let prefix = "R-"

    /// A new random handle.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// A new handle drawn from `generator`, so a test can fix the draw.
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        prefix + String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "2" })
    }

    /// True when `value` has the shape of a handle. Tools check this before
    /// a lookup, so a malformed argument is refused with a clear message.
    public static func isWellFormed(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let body = value.dropFirst(prefix.count)
        return body.count == length && body.allSatisfy(alphabet.contains)
    }
}
