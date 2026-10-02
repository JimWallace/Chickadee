// APIServer/LTI/LTIRoster.swift
//
// Reduces an NRPS membership list into the classlist index the roster
// reconciler already reads (docs/lti-1-3.md "Roster through NRPS"), so the
// LMS and Valence rosters go through one set of matching rules.
//
// NRPS names a member by LTI subject, not by username. A member's identity
// keys are therefore the Chickadee username linked to its subject (once that
// student has launched) and its student number (when the platform sends one).
//
// `preLinks` uses the same student number to link a member's subject to a
// Chickadee account before the student launches, so the AGS sweep can send
// grades for a student who never opens Chickadee from the LMS.

import Core
import Foundation

enum LTIRoster {
    /// The index of every active member.
    static func identityIndex(members: [LTIMember], usernamesBySubject: [String: String]) -> BrightSpaceIdentityIndex {
        BrightSpaceIdentityIndex(
            classlist: members.filter(\.isActive).map { member in
                BrightSpaceClasslistEntry(
                    orgDefinedID: member.sourcedID, username: usernamesBySubject[member.userID], userID: nil)
            })
    }

    /// True when the membership carries student numbers, so a student number
    /// missing from it is an answer rather than a gap in what the LMS sends.
    static func sendsStudentNumbers(_ members: [LTIMember]) -> Bool {
        members.contains { !($0.sourcedID ?? "").isEmpty }
    }

    /// Whether the check may flag a student as not in the LMS course: it may
    /// when the student has launched (the LMS knows their subject), or when
    /// the membership carries student numbers and the student has one.
    static func hasIdentityKey(hasLaunched: Bool, studentID: String?, membershipSendsStudentNumbers: Bool) -> Bool {
        hasLaunched || (membershipSendsStudentNumbers && !(studentID ?? "").isEmpty)
    }

    /// A course student the pre-link may consider.
    struct Candidate: Equatable, Sendable {
        let userID: UUID
        let studentID: String?
    }

    /// One subject to link to one account.
    struct PreLink: Equatable, Sendable {
        let subject: String
        let userID: UUID
    }

    /// The links a roster read can make before any launch: an active member
    /// with the Learner role and a student number, matched to the one course
    /// student with that number. A number that two members or two students
    /// share links nobody, since a link decides whose account a later launch
    /// signs in to. A subject or an account that already has a link on the
    /// platform is left alone, as a launch leaves it.
    static func preLinks(
        members: [LTIMember], students: [Candidate], linkedSubjects: Set<String>, linkedUserIDs: Set<UUID>
    ) -> [PreLink] {
        let learners = members.filter {
            $0.isActive && LTIRoleMapping.courseRole(forRoles: $0.roles ?? []) == .student
        }
        let membersByNumber = Dictionary(grouping: learners) { studentNumber($0.sourcedID) }
        let studentsByNumber = Dictionary(grouping: students) { studentNumber($0.studentID) }
        return learners.compactMap { member in
            guard let number = studentNumber(member.sourcedID),
                membersByNumber[number]?.count == 1,
                let matches = studentsByNumber[number], matches.count == 1,
                let student = matches.first,
                !linkedSubjects.contains(member.userID),
                !linkedUserIDs.contains(student.userID)
            else { return nil }
            return PreLink(subject: member.userID, userID: student.userID)
        }
    }

    /// The trimmed student number, or nil when it is blank.
    private static func studentNumber(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
