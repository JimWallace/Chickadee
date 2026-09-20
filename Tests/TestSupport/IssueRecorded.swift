// Tests/TestSupport/IssueRecorded.swift
//
// One definition for all three test targets. It used to be declared once in
// APITests and once in WorkerTests, identical to the character.

/// Wraps a "the test cannot proceed" condition as a throwable error.
///
/// Use from a helper where the setup is broken: the test surfaces the message
/// and fails. It is never a skip. A condition the host may legitimately not
/// meet (an interpreter on PATH, CI itself) is a `ConditionTrait` on the test
/// instead, so the run reports a skip with a reason.
public struct IssueRecorded: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
