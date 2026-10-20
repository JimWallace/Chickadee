// Tests/APITests/Groups/CompositePerGroupFeedTests.swift
//
// The composite feed of a class composite run once per lab group
// (docs/lab-groups.md, slice 4a), through the route: staff choose the group
// with `?group=` and get nothing without one, and a student reads the image of
// the group their slot is in.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositePerGroupFeedTests {

    private let setupID = "cpgf_setup"

    @Test func staffChooseTheGroupAndAStudentReadsTheirOwn() async throws {
        try await withWebRoutesApp { app in
            let staffCookie = try await wrLoginAsInstructor(on: app)
            try await wrEnrollUser(
                try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first()), on: app)
            let studentCookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let studentID = try student.requireID()

            let courseID = try await wrMakeCourse(on: app).requireID()
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
            let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
            try await CourseGroupStore.setMembership(userID: studentID, groupID: labA, in: set, on: app.db)
            let spec = CompositeSpec(
                compositor: .tile, layout: .grid(columns: 3, rows: 2),
                contribution: CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8),
                dealOrder: .rowMajor)
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
                activity: ClassActivity(kind: .classComposite, composite: spec, runsPerGroup: true))
            let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
            let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)

            try await joinSession(assignmentID: assignment.requireID(), groupID: labA, userID: studentID, on: app.db)
            await CompositeSlots.dealOnOpen(setup: setup, assignment: assignment, userID: studentID, on: app.db)

            func feed(_ query: String, cookie: String) async throws -> (HTTPStatus, [Int]) {
                var result: (HTTPStatus, [Int]) = (.ok, [])
                try await app.asyncTest(
                    .GET, "/testsetups/\(setupID)/composite\(query)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        let slots =
                            res.status == .ok ? try res.content.decode(CompositeSnapshot.self).slots.map(\.slot) : []
                        result = (res.status, slots)
                    })
                return result
            }
            #expect(try await feed("", cookie: staffCookie).0 == .notFound, "staff choose a group")
            #expect(try await feed("?group=\(labA.uuidString)", cookie: staffCookie) == (.ok, [0]))
            #expect(try await feed("?group=\(labB.uuidString)", cookie: staffCookie) == (.ok, []))
            #expect(
                try await feed("?group=\(labB.uuidString)", cookie: studentCookie) == (.ok, [0]),
                "a student reads their own slot's group, whatever they ask for")
        }
    }
}
