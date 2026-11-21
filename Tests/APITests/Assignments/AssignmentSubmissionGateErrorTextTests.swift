// Tests/APITests/Assignments/AssignmentSubmissionGateErrorTextTests.swift
//
// What a student reads when the submission gate refuses them, for example
// when a per-group activity refuses a student outside every group session.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct AssignmentSubmissionGateErrorTextTests {

    @Test func aStudentOutsideEveryGroupSessionIsToldToJoinByTheCode() {
        let error = AssignmentSubmissionGateError.notInGroupSession
        #expect(error.status == .forbidden)
        #expect(error.reason == "This activity runs in your lab. Enter the code on the screen at /join to take part.")
    }

    @Test(arguments: [
        AssignmentSubmissionGateError.closed,
        .activityNotYetOpen(opensAtText: "10:00"),
        .activityClosed(closedAtText: "11:00"),
        .notInGroupSession,
    ])
    func everyGateRefusalIsForbidden(_ error: AssignmentSubmissionGateError) {
        #expect(error.status == .forbidden)
        #expect(!error.reason.isEmpty)
    }
}
