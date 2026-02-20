// Core/Job.swift
//
// Shared job descriptor returned by POST /api/v1/worker/request.
// Defined in Core so both APIServer and Worker can reference it without
// introducing a cross-target dependency between the two executables.

import Foundation

/// A unit of work handed to a worker after it wins a polling request.
public struct Job: Codable, Sendable {
    public let submissionID: String
    public let testSetupID: String
    /// How many times this student has submitted against this test setup (1-based).
    public let attemptNumber: Int
    /// URL the worker should GET to download the submission file.
    public let submissionURL: URL
    /// URL the worker should GET to download the test-setup zip.
    public let testSetupURL: URL
    /// Parsed manifest — avoids a second round-trip to fetch it separately.
    public let manifest: TestProperties
    /// Non-nil when the submission is a raw file (not a zip).
    /// The worker copies it into the test directory under this filename.
    public let submissionFilename: String?

    public init(
        submissionID: String,
        testSetupID: String,
        attemptNumber: Int,
        submissionURL: URL,
        testSetupURL: URL,
        manifest: TestProperties,
        submissionFilename: String? = nil
    ) {
        self.submissionID       = submissionID
        self.testSetupID        = testSetupID
        self.attemptNumber      = attemptNumber
        self.submissionURL      = submissionURL
        self.testSetupURL       = testSetupURL
        self.manifest           = manifest
        self.submissionFilename = submissionFilename
    }
}
