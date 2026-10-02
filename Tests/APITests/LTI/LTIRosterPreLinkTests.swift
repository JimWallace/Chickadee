// Tests/APITests/LTI/LTIRosterPreLinkTests.swift
//
// The pre-launch link rule (docs/lti-1-3.md "Roster through NRPS"): an LMS
// learner links to a course student only through a student number that names
// exactly one of each, and existing links are left alone.

import Foundation
import Testing

@testable import APIServer

@Suite struct LTIRosterPreLinkTests {
    static func learner(_ subject: String, _ number: String?, status: String? = nil) -> LTIMember {
        LTIMember(userID: subject, roles: [LTITestPlatform.learner], status: status, sourcedID: number)
    }

    static func student(_ number: String?) -> LTIRoster.Candidate {
        LTIRoster.Candidate(userID: UUID(), studentID: number)
    }

    @Test func aUniqueStudentNumberLinksTheLearner() {
        let alice = Self.student("20812345")
        let links = LTIRoster.preLinks(
            members: [Self.learner("subject-a", " 20812345 ")], students: [alice, Self.student(nil)],
            linkedSubjects: [], linkedUserIDs: [])
        #expect(links == [LTIRoster.PreLink(subject: "subject-a", userID: alice.userID)])
    }

    @Test func aSharedNumberLinksNobody() {
        let twoMembers = LTIRoster.preLinks(
            members: [Self.learner("subject-a", "208"), Self.learner("subject-b", "208")],
            students: [Self.student("208")], linkedSubjects: [], linkedUserIDs: [])
        #expect(twoMembers.isEmpty)
        let twoStudents = LTIRoster.preLinks(
            members: [Self.learner("subject-a", "208")], students: [Self.student("208"), Self.student("208")],
            linkedSubjects: [], linkedUserIDs: [])
        #expect(twoStudents.isEmpty)
    }

    @Test func onlyActiveLearnersAreLinked() {
        let teacher = LTIMember(
            userID: "subject-i", roles: [LTITestPlatform.instructor], status: nil, sourcedID: "301")
        let noRoles = LTIMember(userID: "subject-n", roles: nil, status: nil, sourcedID: "302")
        let links = LTIRoster.preLinks(
            members: [teacher, noRoles, Self.learner("subject-x", "303", status: "Inactive")],
            students: [Self.student("301"), Self.student("302"), Self.student("303")],
            linkedSubjects: [], linkedUserIDs: [])
        #expect(links.isEmpty)
    }

    @Test func existingLinksAreLeftAlone() {
        let launched = Self.student("401")
        let links = LTIRoster.preLinks(
            members: [Self.learner("subject-a", "401"), Self.learner("subject-b", "402")],
            students: [launched, Self.student("402")],
            linkedSubjects: ["subject-b"], linkedUserIDs: [launched.userID])
        #expect(links.isEmpty)
    }

    @Test func aBlankNumberMatchesNothing() {
        let links = LTIRoster.preLinks(
            members: [Self.learner("subject-a", " "), Self.learner("subject-b", nil)],
            students: [Self.student(""), Self.student(nil)], linkedSubjects: [], linkedUserIDs: [])
        #expect(links.isEmpty)
    }
}
