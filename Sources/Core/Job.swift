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
    /// URL the worker should GET to download the submission zip.
    public let submissionURL: URL
    /// URL the worker should GET to download the test-setup zip.
    public let testSetupURL: URL
    /// Parsed manifest — avoids a second round-trip to fetch it separately.
    public let manifest: TestProperties

    public init(
        submissionID: String,
        testSetupID: String,
        submissionURL: URL,
        testSetupURL: URL,
        manifest: TestProperties
    ) {
        self.submissionID  = submissionID
        self.testSetupID   = testSetupID
        self.submissionURL = submissionURL
        self.testSetupURL  = testSetupURL
        self.manifest      = manifest
    }
}
