// APIServer/Helpers/StaffProvisioning.swift
//
// Adds a person to a course at a staff role before they have ever logged in.
// The instructor roster (`POST /courses/:courseID/staff`) and the admin course
// pages (`POST /admin/courses`, `POST /admin/courses/:courseID/staff`) share
// this one path, so the doors cannot drift (docs/multi-course-roles.md).

import Core
import Fluent
import Foundation
import Vapor

/// Why a staff identifier was refused.
enum StaffProvisioningError: Error, Equatable {
    /// The identifier is empty, too long, or holds a character that a
    /// username or email address cannot hold.
    case invalidIdentifier
    /// No account matches, and the identifier is an email address. An SSO
    /// login adopts a placeholder by username only, so a placeholder named by
    /// an email address is never adopted: the real login makes a second
    /// account and the staff role stays on the orphan.
    case emailWithoutAccount
    /// No account matches, and the caller does not allow a placeholder.
    case unknownUser
}

/// The outcome of a successful `provisionStaffEnrollment` call.
struct StaffProvisioningResult: Sendable {
    let userID: UUID
    let username: String
    /// True when the call created a placeholder account.
    let createdPlaceholder: Bool
}

/// Enrolls the person that `identifier` names in `courseID` at `role`, or
/// promotes their existing enrollment in place.
///
/// An existing account matches by username or by email. When none matches and
/// `allowPlaceholder` is true, a username-shaped identifier gets an SSO-style
/// placeholder account (no local password, no external subject) that the
/// person's first SSO login adopts by username
/// (`SSOAuthRoutes.adoptManuallyRegisteredStub`). The caller checks that
/// `role` is a staff role and records the audit entries
/// (`recordStaffProvisioning`).
func provisionStaffEnrollment(
    identifier: String,
    role: CourseRole,
    courseID: UUID,
    allowPlaceholder: Bool,
    on db: any Database
) async throws -> StaffProvisioningResult {
    guard isAcceptableUsernameForEnrollment(identifier) else {
        throw StaffProvisioningError.invalidIdentifier
    }

    let existing = try await APIUser.query(on: db)
        .group(.or) { or in
            or.filter(\.$username == identifier)
            or.filter(\.$email == identifier)
        }
        .first()

    let user: APIUser
    let createdPlaceholder: Bool
    if let existing {
        user = existing
        createdPlaceholder = false
    } else {
        guard !identifier.contains("@") else { throw StaffProvisioningError.emailWithoutAccount }
        guard allowPlaceholder else { throw StaffProvisioningError.unknownUser }
        user = APIUser(
            username: identifier,
            passwordHash: "",  // SSO users have no local password
            role: UserRole.user.rawValue,  // deployment role is user; staff authority is per-course
            authProvider: "duo-oidc"
        )
        try await user.save(on: db)
        createdPlaceholder = true
    }
    let userID = try user.requireID()

    if let enrollment = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .filter(\.$userID == userID)
        .first()
    {
        enrollment.role = role
        try await enrollment.save(on: db)
    } else {
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: role)
            .save(on: db)
    }
    return StaffProvisioningResult(
        userID: userID, username: user.username, createdPlaceholder: createdPlaceholder)
}

/// Records the audit entries for a `provisionStaffEnrollment` result: a
/// `userProvisioned` entry when a placeholder was created, then the role.
func recordStaffProvisioning(
    _ result: StaffProvisioningResult,
    role: CourseRole,
    courseID: UUID,
    source: String,
    on req: Request
) async {
    if result.createdPlaceholder {
        await AuditLogger.record(
            action: .userProvisioned,
            targetType: .user,
            targetID: result.userID.uuidString,
            metadata: ["username": result.username, "source": source],
            courseID: courseID,
            on: req
        )
    }
    await AuditLogger.record(
        action: .enrollmentRoleChanged,
        targetType: .enrollment,
        targetID: result.userID.uuidString,
        metadata: [
            "course_id": courseID.uuidString,
            "subject_user_id": result.userID.uuidString,
            "role": role.rawValue,
            "source": source,
        ],
        on: req
    )
}

extension StaffProvisioningError {
    /// The flash for `.emailWithoutAccount`, shared by the instructor and
    /// admin forms.
    static let emailWithoutAccountMessage =
        "No account has that email address. Enter the person's username instead."
    /// The flash for `.unknownUser`. Only a local-sign-in deployment refuses
    /// a placeholder, because nothing could adopt it.
    static let unknownUserMessage =
        "No account has that username. This server uses local sign-in, so the person must register first."
}

/// Why the admin course page's staff form was refused. The raw value is the
/// `staffError` query value.
enum StaffFormError: String, CaseIterable {
    case role
    case identifier
    case email
    case unknown

    init(_ error: StaffProvisioningError) {
        switch error {
        case .invalidIdentifier: self = .identifier
        case .emailWithoutAccount: self = .email
        case .unknownUser: self = .unknown
        }
    }

    var message: String {
        switch self {
        case .role: "Choose a staff role (TA or Instructor)."
        case .identifier: "Enter a valid username or email address."
        case .email: StaffProvisioningError.emailWithoutAccountMessage
        case .unknown: StaffProvisioningError.unknownUserMessage
        }
    }

    /// The message for a `staffError` query value, or nil for any other value.
    static func message(forQuery value: String?) -> String? {
        value.flatMap(Self.init(rawValue:))?.message
    }
}
