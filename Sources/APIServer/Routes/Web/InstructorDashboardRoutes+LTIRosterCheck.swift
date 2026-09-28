// APIServer/Routes/Web/InstructorDashboardRoutes+LTIRosterCheck.swift
//
// The "Check against LEARN" roster check, read from the LMS through NRPS
// instead of the Valence classlist (docs/lti-1-3.md "Roster through NRPS").
// `studentsLearnCheck` sends a course here when the course uses the LTI grade
// service, or when it has an NRPS URL and no Valence link. The result has the
// same shape, so the Students tab needs no change to show it.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {
    /// True when the roster check reads the LMS membership instead of the
    /// Valence classlist.
    static func rosterCheckUsesLTI(course: APICourse, valenceConfigured: Bool) -> Bool {
        guard course.ltiMembershipsURL != nil, course.ltiPlatformID != nil else { return false }
        return course.usesLTIGrades || !valenceConfigured || (course.brightspaceOrgUnitID ?? "").isEmpty
    }

    func ltiRosterCheck(course: APICourse, courseID: UUID, req: Request) async throws -> LearnRosterCheckResult {
        guard let membershipsURL = course.ltiMembershipsURL, let platformID = course.ltiPlatformID,
            let platform = try await APILTIPlatform.find(platformID, on: req.db), platform.enabled
        else { return .unavailable("The LMS link for this course is not active.") }

        let members: [LTIMember]
        do {
            members = try await req.application.ltiServiceClient.members(
                membershipsURL: membershipsURL,
                platform: .init(id: platformID, clientID: platform.clientID, accessTokenURL: platform.accessTokenURL),
                keys: try await req.application.ltiToolKeyAuthority())
        } catch {
            req.logger.warning("LTI membership read failed: \(error)")
            return .unavailable("Chickadee could not read the class list from the LMS.")
        }

        let studentIDs = Array(try await studentUserIDsInCourse(courseID, on: req.db))
        var students: [APIUser] = []
        var identities: [APILTIIdentity] = []
        for chunk in chunkedForInFilter(studentIDs) {
            students += try await APIUser.query(on: req.db).filter(\.$id ~~ chunk).all()
            identities += try await APILTIIdentity.query(on: req.db)
                .filter(\.$platformID == platformID)
                .filter(\.$userID ~~ chunk)
                .all()
        }
        let usernames = Dictionary(students.compactMap { user in user.id.map { ($0, user.username) } }) { first, _ in
            first
        }
        let usernamesBySubject = Dictionary(
            identities.compactMap { identity in usernames[identity.userID].map { (identity.subject, $0) } }
        ) { first, _ in first }
        let launched = Set(identities.map(\.userID))
        let index = LTIRoster.identityIndex(members: members, usernamesBySubject: usernamesBySubject)
        let sendsStudentNumbers = LTIRoster.sendsStudentNumbers(members)

        var notOnLearn: [String] = []
        var unverifiable: [String] = []
        for student in students {
            guard let id = student.id else { continue }
            let status = LearnRosterReconciler.classify(
                candidateKeys: [student.studentID, student.username],
                hasIdentityKey: LTIRoster.hasIdentityKey(
                    hasLaunched: launched.contains(id), studentID: student.studentID,
                    membershipSendsStudentNumbers: sendsStudentNumbers),
                learnIdentities: index)
            switch status {
            case .onLearn: break
            case .notOnLearn: notOnLearn.append(id.uuidString)
            case .unverifiable: unverifiable.append(id.uuidString)
            }
        }

        // A pending pre-enrollment has only a username, which NRPS does not
        // send: it can never be checked here.
        let pending = try await APIPreEnrollment.query(on: req.db).filter(\.$course.$id == courseID).all()
        unverifiable += pending.compactMap { $0.id?.uuidString }

        let checked = students.count + pending.count
        let activeMembers = members.filter(\.isActive).count
        var message =
            "Checked \(checked) against \(activeMembers) in the LMS: \(notOnLearn.count) not in the LMS course"
        if !unverifiable.isEmpty {
            message += ", \(unverifiable.count) could not be matched"
        }
        message += "."
        return LearnRosterCheckResult(
            ok: true, message: message, configured: true, courseLinked: true, notOnLearn: notOnLearn,
            unverifiable: unverifiable, checkedCount: checked, learnCount: activeMembers)
    }
}
