// Tests/APITests/LTI/LTIRosterTests.swift
//
// The NRPS membership reduction (docs/lti-1-3.md "Roster through NRPS"):
// which members count, how a subject becomes a matchable username, and when
// the check may flag a student as not in the LMS course.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct LTIRosterTests {
    static func member(_ subject: String, status: String? = nil, sourcedID: String? = nil) -> LTIMember {
        LTIMember(userID: subject, roles: [LTITestPlatform.learner], status: status, sourcedID: sourcedID)
    }

    @Test func aLaunchedMemberMatchesByUsername() {
        let index = LTIRoster.identityIndex(
            members: [Self.member("subject-1")], usernamesBySubject: ["subject-1": "jdoe"])
        #expect(index.contains("jdoe"))
        #expect(!index.contains("subject-1"))
    }

    @Test func aStudentNumberMatchesWithoutALaunch() {
        let index = LTIRoster.identityIndex(
            members: [Self.member("subject-2", sourcedID: "20812345")], usernamesBySubject: [:])
        #expect(index.contains("20812345"))
    }

    @Test func onlyActiveMembersCount() {
        let index = LTIRoster.identityIndex(
            members: [
                Self.member("subject-1", status: "Inactive"), Self.member("subject-2", status: "Deleted"),
                Self.member("subject-3", status: "Active"),
            ],
            usernamesBySubject: ["subject-1": "gone", "subject-2": "deleted", "subject-3": "here"])
        #expect(!index.contains("gone"))
        #expect(!index.contains("deleted"))
        #expect(index.contains("here"))
    }

    @Test func aStudentIsFlaggedOnlyWhenTheLMSCouldKnowThem() {
        #expect(LTIRoster.hasIdentityKey(hasLaunched: true, studentID: nil, membershipSendsStudentNumbers: false))
        #expect(LTIRoster.hasIdentityKey(hasLaunched: false, studentID: "208", membershipSendsStudentNumbers: true))
        #expect(!LTIRoster.hasIdentityKey(hasLaunched: false, studentID: "208", membershipSendsStudentNumbers: false))
        #expect(!LTIRoster.hasIdentityKey(hasLaunched: false, studentID: nil, membershipSendsStudentNumbers: true))
    }

    @Test func studentNumbersAreDetected() {
        #expect(LTIRoster.sendsStudentNumbers([Self.member("a"), Self.member("b", sourcedID: "208")]))
        #expect(!LTIRoster.sendsStudentNumbers([Self.member("a"), Self.member("b", sourcedID: "")]))
    }

    @Test func theNextPageComesFromTheLinkHeader() {
        var headers = HTTPHeaders()
        headers.add(
            name: .link,
            value: #"<https://lms.example.edu/prev>; rel="prev", <https://lms.example.edu/next>; rel="next""#)
        #expect(LTIServiceClient.nextPageURL(headers) == "https://lms.example.edu/next")
        #expect(LTIServiceClient.nextPageURL(HTTPHeaders()) == nil)
    }
}
