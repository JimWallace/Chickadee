// APIServer/LTI/LTIRoster.swift
//
// Reduces an NRPS membership list into the classlist index the roster
// reconciler already reads (docs/lti-1-3.md "Roster through NRPS"), so the
// LMS and Valence rosters go through one set of matching rules.
//
// NRPS names a member by LTI subject, not by username. A member's identity
// keys are therefore the Chickadee username linked to its subject (once that
// student has launched) and its student number (when the platform sends one).

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
}
