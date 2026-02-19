// Core/Job.swift
//
// Shared job descriptor returned by POST /api/v1/worker/request.
// Defined in Core so both APIServer and Worker can reference it without
// introducing a cross-target dependency between the two executables.

import Foundation

/// A unit of work handed to a worker after it wins a polling request.
struct Job: Codable, Sendable {
    let submissionID: String
    let testSetupID: String
    /// URL the worker should GET to download the submission zip.
    let submissionURL: URL
    /// URL the worker should GET to download the test-setup zip.
    let testSetupURL: URL
    /// Parsed manifest — avoids a second round-trip to fetch it separately.
    let manifest: TestSetupManifest
}
