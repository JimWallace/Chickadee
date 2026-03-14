// Core/CourseBundleManifest.swift
//
// Codable types for the Chickadee course bundle format (schemaVersion 1).
//
// Bundle ZIP layout:
//   bundle.json                        — this manifest (JSON, iso8601 dates)
//   testsetups/<originalSetupID>.zip   — instructor test-setup zips
//   submissions/<originalSubID>.<ext>  — student submission files
//
// bundleID values are stable cross-references within a single bundle.
// They are NEVER reused as DB primary keys on the target instance;
// all IDs are regenerated on import.
//
// Password hashes are never included. User entries carry only
// username, displayName, email, and role.

import Foundation

// MARK: - Top-level manifest

public struct CourseBundleManifest: Codable, Sendable {
    /// Always 1 for this format version.
    public let schemaVersion: Int
    public let exportedAt: Date
    /// Username of the admin who performed the export.
    public let exportedBy: String
    /// Value of ChickadeeVersion.current at export time.
    public let chickadeeVersion: String
    public let course: BundledCourse
    /// All users who appear in submissions or enrollments.
    public let users: [BundledUser]
    /// bundleIDs of users enrolled in the course.
    public let enrolledUserBundleIDs: [String]
    public let assignments: [BundledAssignment]
    public let testSetups: [BundledTestSetup]
    /// Student submissions only (kind == "student"); validation runs excluded.
    public let submissions: [BundledSubmission]
    /// Results paired with their submissions.
    public let results: [BundledResult]

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date,
        exportedBy: String,
        chickadeeVersion: String,
        course: BundledCourse,
        users: [BundledUser],
        enrolledUserBundleIDs: [String],
        assignments: [BundledAssignment],
        testSetups: [BundledTestSetup],
        submissions: [BundledSubmission],
        results: [BundledResult]
    ) {
        self.schemaVersion        = schemaVersion
        self.exportedAt           = exportedAt
        self.exportedBy           = exportedBy
        self.chickadeeVersion     = chickadeeVersion
        self.course               = course
        self.users                = users
        self.enrolledUserBundleIDs = enrolledUserBundleIDs
        self.assignments          = assignments
        self.testSetups           = testSetups
        self.submissions          = submissions
        self.results              = results
    }
}

// MARK: - Nested bundle types

public struct BundledCourse: Codable, Sendable {
    public let code: String
    public let name: String
    /// nil in bundles exported before this field was added; defaults to true on import.
    public let openEnrollment: Bool?

    public init(code: String, name: String, openEnrollment: Bool? = nil) {
        self.code           = code
        self.name           = name
        self.openEnrollment = openEnrollment
    }
}

public struct BundledUser: Codable, Sendable {
    /// Stable cross-reference within this bundle (e.g. "user_1").
    public let bundleID: String
    public let username: String
    public let displayName: String?
    public let email: String?
    /// "student" | "instructor" | "admin"
    public let role: String

    public init(bundleID: String, username: String, displayName: String?,
                email: String?, role: String) {
        self.bundleID    = bundleID
        self.username    = username
        self.displayName = displayName
        self.email       = email
        self.role        = role
    }
}

public struct BundledAssignment: Codable, Sendable {
    public let bundleID: String
    public let title: String
    public let dueAt: Date?
    public let isOpen: Bool
    public let sortOrder: Int?
    /// References BundledTestSetup.bundleID.
    public let testSetupBundleID: String

    public init(bundleID: String, title: String, dueAt: Date?, isOpen: Bool,
                sortOrder: Int?, testSetupBundleID: String) {
        self.bundleID           = bundleID
        self.title              = title
        self.dueAt              = dueAt
        self.isOpen             = isOpen
        self.sortOrder          = sortOrder
        self.testSetupBundleID  = testSetupBundleID
    }
}

public struct BundledTestSetup: Codable, Sendable {
    public let bundleID: String
    /// Original DB ID from the source instance — for debugging only, never reused.
    public let originalID: String
    /// Raw TestProperties JSON string.
    public let manifest: String
    /// Relative path within the bundle ZIP: "testsetups/<originalID>.zip"
    public let zipFilename: String

    public init(bundleID: String, originalID: String, manifest: String,
                zipFilename: String) {
        self.bundleID    = bundleID
        self.originalID  = originalID
        self.manifest    = manifest
        self.zipFilename = zipFilename
    }
}

public struct BundledSubmission: Codable, Sendable {
    public let bundleID: String
    /// References BundledUser.bundleID.
    public let userBundleID: String
    /// References BundledTestSetup.bundleID.
    public let testSetupBundleID: String
    public let attemptNumber: Int
    public let submittedAt: Date?
    /// Original submission filename (e.g. "warmup.py").
    public let filename: String?
    /// Relative path within the bundle ZIP: "submissions/<originalSubID>.<ext>"
    public let submissionFilename: String

    public init(bundleID: String, userBundleID: String, testSetupBundleID: String,
                attemptNumber: Int, submittedAt: Date?, filename: String?,
                submissionFilename: String) {
        self.bundleID           = bundleID
        self.userBundleID       = userBundleID
        self.testSetupBundleID  = testSetupBundleID
        self.attemptNumber      = attemptNumber
        self.submittedAt        = submittedAt
        self.filename           = filename
        self.submissionFilename = submissionFilename
    }
}

public struct BundledResult: Codable, Sendable {
    /// References BundledSubmission.bundleID.
    public let submissionBundleID: String
    /// Raw TestOutcomeCollection JSON string.
    public let collectionJSON: String
    /// "worker" or "browser"
    public let source: String
    public let receivedAt: Date?

    public init(submissionBundleID: String, collectionJSON: String,
                source: String, receivedAt: Date?) {
        self.submissionBundleID = submissionBundleID
        self.collectionJSON     = collectionJSON
        self.source             = source
        self.receivedAt         = receivedAt
    }
}
