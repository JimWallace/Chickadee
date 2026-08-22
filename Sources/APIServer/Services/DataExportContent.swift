// APIServer/Services/DataExportContent.swift
//
// What goes *inside* a personal-data export (#557 — FIPPA / PIPEDA subject
// access): the Sendable snapshot types for each JSON file in the zip, the
// DB gather queries that populate them, and the README manifest text.
// The pipeline that stages, zips, and tracks the export lives in
// `DataExportService.swift`.
//
// Privacy rules encoded here:
//   • Test outcomes are tier-filtered with the same policy as the results
//     API (`visibleTiers`) — the export contains exactly what the user can
//     already see, never hidden secret/release detail.
//   • Audit entries where the user is the *actor* include their own
//     IP / user-agent; entries where they are only the *subject* omit
//     those fields (they belong to whoever performed the action).
//   • `passwordHash` and per-assignment personalization seeds are never
//     exported (credentials and server-side grading secrets).

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Snapshot types (one per JSON file in the zip)

struct DataExportProfile: Codable, Sendable {
    let accountID: String
    let username: String
    let preferredName: String?
    let displayName: String?
    let email: String?
    let userIdentifier: String?
    let studentID: String?
    let deploymentRole: String
    let authProvider: String?
    let ssoSubject: String?
    let accountCreatedAt: Date?
    let lastLoginAt: Date?
    let lastSeenAt: Date?
    /// The student's generated chickadee, as stored: the slot choices, not an
    /// image. Personal information about them, so it belongs in the export;
    /// nil when they have never had one materialized.
    let avatar: AvatarSpec?
}

struct DataExportEnrollment: Codable, Sendable {
    let courseCode: String
    let courseName: String
    let role: String
    let enrolledAt: Date?
    let learnSection: String?
    /// The pseudonym this student appears under in this course's class-facing
    /// pages. nil before one has been materialized.
    let avatarHandle: String?
}

struct DataExportSubmission: Codable, Sendable {
    let submissionID: String
    let courseCode: String?
    let assignmentTitle: String?
    let kind: String
    let status: String
    let attemptNumber: Int?
    let submittedAt: Date?
    let originalFilename: String?
    /// Path of the uploaded file inside this zip, nil when the file was no
    /// longer on disk at export time.
    let filePath: String?
    /// Path of the grading results JSON inside this zip, nil when the
    /// submission has no stored result yet.
    let resultsPath: String?
}

struct DataExportAuditEntry: Codable, Sendable {
    let occurredAt: Date?
    let action: String
    let actionLabel: String
    /// "actor" when the user performed the action themselves, "subject"
    /// when someone else's action was about them (e.g. they were enrolled).
    let involvement: String
    let targetType: String?
    let targetID: String?
    /// Only on "subject" rows: who performed the action.
    let performedBy: String?
    /// Only on "actor" rows — the IP / user-agent belong to the actor.
    let ipAddress: String?
    let userAgent: String?
    let details: [String: String]?
}

struct DataExportGradingAdjustments: Codable, Sendable {
    struct Extension: Codable, Sendable {
        let assignmentTitle: String?
        let extendedDueAt: Date
        let note: String?
        let grantedAt: Date?
    }
    struct GradeOverride: Codable, Sendable {
        let assignmentTitle: String?
        let overridePercent: Int
        let note: String?
        let grantedAt: Date?
    }
    struct SecretRevealSpend: Codable, Sendable {
        let assignmentTitle: String?
        let spentAt: Date?
    }
    struct SlipDaySpend: Codable, Sendable {
        let assignmentTitle: String?
        let spentAt: Date?
        /// The per-student deadline this spend produced.
        let extendedDueAt: Date
        /// Set when course staff returned the day to the budget.
        let refundedAt: Date?
    }
    let deadlineExtensions: [Extension]
    let gradeOverrides: [GradeOverride]
    let secretRevealTokensSpent: [SecretRevealSpend]
    let slipDaysSpent: [SlipDaySpend]
}

/// Everything gathered from the database for one export, in Sendable form,
/// plus the on-disk submission files to copy into the zip.
struct DataExportContent: Sendable {
    let profile: DataExportProfile
    let enrollments: [DataExportEnrollment]
    let submissions: [DataExportSubmission]
    /// Tier-filtered results JSON bytes keyed by in-zip relative path.
    let resultFiles: [String: Data]
    let auditEntries: [DataExportAuditEntry]
    let gradingAdjustments: DataExportGradingAdjustments
    /// (absolute source path, in-zip relative path) submission file copies.
    let fileCopies: [(sourcePath: String, relativePath: String)]
}

// MARK: - Gather

/// Loads every piece of the export for `user` from the database.  Read-only;
/// all file I/O happens later on the thread pool (`DataExportService`).
func gatherDataExportContent(
    for user: APIUser, on db: Database, now: Date = Date()
) async throws -> DataExportContent {
    let userID = try user.requireID()

    let enrollments = try await gatherEnrollments(userID: userID, on: db)
    let submissionData = try await gatherSubmissions(user: user, on: db, now: now)
    let auditEntries = try await gatherAuditEntries(for: user, on: db)
    let adjustments = try await gatherGradingAdjustments(userID: userID, on: db)

    return DataExportContent(
        profile: DataExportProfile(
            accountID: userID.uuidString,
            username: user.username,
            preferredName: user.preferredName,
            displayName: user.displayName,
            email: user.email,
            userIdentifier: user.userIdentifier,
            studentID: user.studentID,
            deploymentRole: user.role,
            authProvider: user.authProvider,
            ssoSubject: user.externalSubject,
            accountCreatedAt: user.createdAt,
            lastLoginAt: user.lastLoginAt,
            lastSeenAt: user.lastSeenAt,
            avatar: user.avatarSpecJSON.flatMap(AvatarStore.decode)
        ),
        enrollments: enrollments,
        submissions: submissionData.submissions,
        resultFiles: submissionData.resultFiles,
        auditEntries: auditEntries,
        gradingAdjustments: adjustments,
        fileCopies: submissionData.fileCopies
    )
}

private func gatherEnrollments(
    userID: UUID, on db: Database
) async throws -> [DataExportEnrollment] {
    let rows = try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .with(\.$course)
        .all()
    return
        rows
        .map { row in
            DataExportEnrollment(
                courseCode: row.course.code,
                courseName: row.course.name,
                role: row.role.rawValue,
                enrolledAt: row.enrolledAt,
                learnSection: row.brightspaceSection,
                avatarHandle: row.avatarHandle
            )
        }
        .sorted { $0.courseCode < $1.courseCode }
}

private struct GatheredSubmissions: Sendable {
    let submissions: [DataExportSubmission]
    let resultFiles: [String: Data]
    let fileCopies: [(sourcePath: String, relativePath: String)]
}

private func gatherSubmissions(
    user: APIUser, on db: Database, now: Date
) async throws -> GatheredSubmissions {
    let userID = try user.requireID()
    let submissions = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .sort(\.$submittedAt, .ascending)
        .all()
    guard !submissions.isEmpty else {
        return GatheredSubmissions(submissions: [], resultFiles: [:], fileCopies: [])
    }

    let setupIDs = Array(Set(submissions.map(\.testSetupID)))
    let setups = try await APITestSetup.query(on: db).filter(\.$id ~~ setupIDs).all()
    let setupByID = Dictionary(setups.compactMap { s in s.id.map { ($0, s) } }) { first, _ in first }
    let assignments = try await APIAssignment.query(on: db)
        .filter(\.$testSetupID ~~ setupIDs)
        .all()
    let assignmentBySetupID = Dictionary(assignments.map { ($0.testSetupID, $0) }) { first, _ in
        first
    }
    let courseIDs = Array(Set(setups.map(\.courseID)))
    let courses =
        courseIDs.isEmpty
        ? [] : try await APICourse.query(on: db).filter(\.$id ~~ courseIDs).all()
    let courseByID = Dictionary(courses.compactMap { c in c.id.map { ($0, c) } }) { first, _ in
        first
    }

    let visibleTiersBySetupID = try await resolveVisibleTiers(
        user: user, setups: setups, assignmentBySetupID: assignmentBySetupID, on: db, now: now)
    let latestResults = try await latestResultBySubmissionID(
        submissionIDs: submissions.compactMap(\.id), on: db)
    let collectionJSONs = try await collectionJSONByResultID(
        for: latestResults.values.compactMap(\.id), on: db)

    var rows: [DataExportSubmission] = []
    var resultFiles: [String: Data] = [:]
    var fileCopies: [(sourcePath: String, relativePath: String)] = []
    for submission in submissions {
        guard let subID = submission.id else { continue }
        let setup = setupByID[submission.testSetupID]
        let course = setup.flatMap { courseByID[$0.courseID] }

        let onDiskName = URL(fileURLWithPath: submission.zipPath).lastPathComponent
        let filePath = "submissions/\(subID)/\(onDiskName)"
        let fileOnDisk = FileManager.default.fileExists(atPath: submission.zipPath)
        if fileOnDisk {
            fileCopies.append((sourcePath: submission.zipPath, relativePath: filePath))
        }

        var resultsPath: String?
        if let result = latestResults[subID], let resultID = result.id,
            let json = collectionJSONs[resultID],
            let tiers = visibleTiersBySetupID[submission.testSetupID],
            let data = tierFilteredCollectionData(collectionJSON: json, visibleTiers: tiers)
        {
            let path = "submissions/\(subID)/results.json"
            resultFiles[path] = data
            resultsPath = path
        }

        rows.append(
            DataExportSubmission(
                submissionID: subID,
                courseCode: course?.code,
                assignmentTitle: assignmentBySetupID[submission.testSetupID]?.title,
                kind: submission.kind,
                status: submission.status,
                attemptNumber: submission.attemptNumber,
                submittedAt: submission.submittedAt,
                originalFilename: submission.filename,
                filePath: fileOnDisk ? filePath : nil,
                resultsPath: resultsPath
            ))
    }
    return GatheredSubmissions(
        submissions: rows, resultFiles: resultFiles, fileCopies: fileCopies)
}

/// The tier set the user may inspect for each test setup, mirroring
/// `SubmissionQueryRoutes.getResults`: staff of the setup's course see all
/// tiers; otherwise release is gated on the user's own effective deadline
/// and secret on a spent reveal token.
private func resolveVisibleTiers(
    user: APIUser,
    setups: [APITestSetup],
    assignmentBySetupID: [String: APIAssignment],
    on db: Database,
    now: Date
) async throws -> [String: Set<String>] {
    var staffByCourseID: [UUID: Bool] = [:]
    var tiersBySetupID: [String: Set<String>] = [:]
    for setup in setups {
        guard let setupID = setup.id else { continue }
        if staffByCourseID[setup.courseID] == nil {
            staffByCourseID[setup.courseID] = try await isCourseStaff(
                user, inCourse: setup.courseID, db: db)
        }
        let isStaff = staffByCourseID[setup.courseID] ?? false
        let assignment = assignmentBySetupID[setupID]
        let releaseDeadline = try await releaseVisibilityDeadline(
            for: assignment, user: user, on: db)
        let reveal = try await SecretRevealState.resolve(
            assignment: assignment, userID: user.id, isStaff: isStaff, on: db)
        tiersBySetupID[setupID] = visibleTiers(
            isStaff: isStaff, effectiveDueAt: releaseDeadline,
            secretRevealed: reveal.revealed, now: now)
    }
    return tiersBySetupID
}

private func latestResultBySubmissionID(
    submissionIDs: [String], on db: Database
) async throws -> [String: APIResult] {
    guard !submissionIDs.isEmpty else { return [:] }
    let results = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ submissionIDs)
        .all()
    var latest: [String: APIResult] = [:]
    for result in results {
        if let existing = latest[result.submissionID],
            (existing.receivedAt ?? .distantPast) >= (result.receivedAt ?? .distantPast)
        {
            continue
        }
        latest[result.submissionID] = result
    }
    return latest
}

/// Decodes a stored collection, filters it to the visible tier set the same
/// way the results API does (real all-tier grade aggregates, only
/// inspectable outcomes), and re-encodes it for the zip.
private func tierFilteredCollectionData(
    collectionJSON: String, visibleTiers: Set<String>
) -> Data? {
    guard let full = decodedCollection(from: collectionJSON) else { return nil }
    let visible = full.filtering(tiers: visibleTiers)
    let filtered = full.replacingOutcomes(with: visible.outcomes)
    return try? dataExportJSONEncoder().encode(filtered)
}

// MARK: - Audit entries

/// Actions whose audit rows identify the affected user only inside
/// `metadata` (`student_username`) rather than via `target_id`; candidates
/// are fetched by action and confirmed against the decoded metadata.
private let metadataSubjectActions: [String] = [
    AuditAction.extensionGranted, .extensionRevoked,
    .gradeOverrideSet, .gradeOverrideCleared,
    .secretRevealRegranted, .submissionRetestForStudent,
    .slipDayRefunded, .slipDayAdjustmentChanged,
].map(\.rawValue)

private func gatherAuditEntries(
    for user: APIUser, on db: Database
) async throws -> [DataExportAuditEntry] {
    let userID = try user.requireID()
    let uuidString = userID.uuidString

    // Entries the user performed, or whose target is the user directly
    // (user.* actions, enrollment.* actions — both stamp target_id with the
    // user's UUID).
    let direct = try await APIAuditLogEntry.query(on: db)
        .group(.or) { or in
            or.filter(\.$actorUserID == userID)
            or.filter(\.$targetID == uuidString)
        }
        .all()

    // Entries about the user that only name them in metadata (extensions,
    // grade overrides, reveal re-grants, per-student retests target the
    // assignment). Candidates by action, confirmed in Swift.
    let metadataCandidates = try await APIAuditLogEntry.query(on: db)
        .filter(\.$action ~~ metadataSubjectActions)
        .all()

    var byID: [UUID: APIAuditLogEntry] = [:]
    for entry in direct {
        if let id = entry.id { byID[id] = entry }
    }
    for entry in metadataCandidates {
        guard let id = entry.id, byID[id] == nil else { continue }
        let details = decodeAuditMetadata(entry.metadata)
        if details["student_username"] == user.username
            || details["subject_username"] == user.username
            || details["subject_user_id"] == uuidString
        {
            byID[id] = entry
        }
    }

    return byID.values
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        .map { entry in
            let isActor = entry.actorUserID == userID
            let display = AuditActionDisplay.categoryLabel(forRaw: entry.action)
            let details = decodeAuditMetadata(entry.metadata)
            return DataExportAuditEntry(
                occurredAt: entry.createdAt,
                action: entry.action,
                actionLabel: display.label,
                involvement: isActor ? "actor" : "subject",
                targetType: entry.targetType,
                targetID: entry.targetID,
                performedBy: isActor ? nil : entry.actorUsername,
                ipAddress: isActor ? entry.remoteAddr : nil,
                userAgent: isActor ? entry.userAgent : nil,
                details: details.isEmpty ? nil : details
            )
        }
}

private func decodeAuditMetadata(_ json: String?) -> [String: String] {
    guard let json, let data = json.data(using: .utf8) else { return [:] }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: String]) ?? [:]
}

// MARK: - Grading adjustments

private func gatherGradingAdjustments(
    userID: UUID, on db: Database
) async throws -> DataExportGradingAdjustments {
    let extensions = try await APIAssignmentExtension.query(on: db)
        .filter(\.$userID == userID)
        .all()
    let overrides = try await APIGradeOverride.query(on: db)
        .filter(\.$userID == userID)
        .all()
    let unlocks = try await APISecretRevealUnlock.query(on: db)
        .filter(\.$userID == userID)
        .all()
    let slipDaySpends = try await APISlipDaySpend.query(on: db)
        .filter(\.$userID == userID)
        .sort(\.$spentAt, .ascending)
        .all()

    // Resolve assignment titles for everything referenced above.
    let assignmentIDs = Array(
        Set(
            extensions.map(\.assignmentID) + unlocks.map(\.assignmentID)
                + slipDaySpends.map(\.assignmentID)))
    let assignmentsByID: [UUID: APIAssignment] =
        assignmentIDs.isEmpty
        ? [:]
        : Dictionary(
            try await APIAssignment.query(on: db).filter(\.$id ~~ assignmentIDs).all()
                .compactMap { a in a.id.map { ($0, a) } }
        ) { first, _ in first }
    let setupIDs = Array(Set(overrides.map(\.testSetupID)))
    let assignmentsBySetupID: [String: APIAssignment] =
        setupIDs.isEmpty
        ? [:]
        : Dictionary(
            try await APIAssignment.query(on: db).filter(\.$testSetupID ~~ setupIDs).all()
                .map { ($0.testSetupID, $0) }
        ) { first, _ in first }

    return DataExportGradingAdjustments(
        deadlineExtensions: extensions.map {
            .init(
                assignmentTitle: assignmentsByID[$0.assignmentID]?.title,
                extendedDueAt: $0.extendedDueAt, note: $0.note, grantedAt: $0.grantedAt)
        },
        gradeOverrides: overrides.map {
            .init(
                assignmentTitle: assignmentsBySetupID[$0.testSetupID]?.title,
                overridePercent: $0.overridePercent, note: $0.note, grantedAt: $0.grantedAt)
        },
        secretRevealTokensSpent: unlocks.map {
            .init(assignmentTitle: assignmentsByID[$0.assignmentID]?.title, spentAt: $0.spentAt)
        },
        slipDaysSpent: slipDaySpends.map {
            .init(
                assignmentTitle: assignmentsByID[$0.assignmentID]?.title,
                spentAt: $0.spentAt, extendedDueAt: $0.extensionDueAt,
                refundedAt: $0.refundedAt)
        }
    )
}

// MARK: - Encoding + README

/// Human-readable, deterministic JSON for everything inside the export.
func dataExportJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

/// The manifest at the root of the zip, explaining each file.  Plain
/// Markdown, addressed to the account owner.
func dataExportReadme(username: String, generatedAt: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return """
        # Your Chickadee data export

        Generated for account **\(username)** on \(formatter.string(from: generatedAt)) \
        by Chickadee v\(ChickadeeVersion.current).

        This archive contains a copy of the personal information Chickadee
        holds about you, provided in support of your right of access under
        Ontario's FIPPA and Canada's PIPEDA.

        ## Contents

        - `profile.json` — your account profile: username, names, email,
          student ID, sign-in provider, account timestamps, and the choices
          behind your generated avatar. Passwords are stored only as one-way
          hashes and are never included.
        - `enrollments.json` — the courses you are enrolled in, your role in
          each, when you enrolled, and the pseudonym you appear under on that
          course's class-facing pages.
        - `submissions.json` — an index of every submission you have made:
          course, assignment, attempt number, timestamps, and where in this
          archive to find the uploaded file and its grading results.
        - `submissions/<id>/` — one folder per submission, holding the file
          you uploaded (under its stored name) and `results.json`, the test
          outcomes for that submission. Results reflect what is visible to
          you at export time: details of hidden (secret-tier) tests, and of
          release-tier tests before their deadline, are not itemized —
          matching what you see on the site. Aggregate counts and grades
          always cover every test.
        - `grading-adjustments.json` — per-student grading records: deadline
          extensions, grade overrides, secret-test reveal tokens you have
          spent, and slip days you have spent (with the deadline each one
          produced and any staff refund).
        - `audit-log.json` — activity records involving your account.
          Entries marked `actor` are actions you performed (with the IP
          address and browser they came from); entries marked `subject` are
          actions performed about your account (e.g. being enrolled in a
          course), without the performer's connection details. Audit records
          are retained for a limited period, so older activity may no longer
          exist.

        Not included: uploaded files that have since been purged from the
        server, and code-execution artifacts that are not retained after
        grading.

        If anything here looks wrong, contact your course instructor or the
        service operator.
        """
}
