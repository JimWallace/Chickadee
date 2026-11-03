// Tests for the course and section loaders in CourseLoaders.swift (#2773).
// They pin the status and message of each refusal, because the loaders
// replace hand-written guards whose errors a client may already read.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseLoadersTests {

    private func request(on app: Application, params: [String: String], caller: APIUser? = nil) -> Request {
        let req = makeTestRequest(on: app)
        for (name, value) in params { req.parameters.set(name, to: value) }
        if let caller { req.auth.login(caller) }
        return req
    }

    private func enroll(_ user: APIUser, in course: APICourse, as role: CourseRole, on app: Application) async throws {
        let row = APICourseEnrollment(userID: try user.requireID(), courseID: try course.requireID(), role: role)
        try await row.save(on: app.db)
    }

    // MARK: - loadCourse

    @Test func loadCourseReturnsTheCourseAndTheRawParameter() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let raw = try course.requireID().uuidString.lowercased()
            let loaded = try await loadCourse(request(on: app, params: ["courseID": raw]))
            #expect(try loaded.course.requireID() == course.requireID())
            #expect(try loaded.id == course.requireID())
            #expect(loaded.idString == raw)
        }
    }

    @Test(arguments: [nil, "not-a-uuid", UUID().uuidString])
    func loadCourseRefusesWithCourseNotFound(_ parameter: String?) async throws {
        try await withTestApp { app in
            _ = try await makeTestCourse(on: app, code: "CS136")
            let params = parameter.map { ["courseID": $0] } ?? [:]
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourse(request(on: app, params: params))
            }
            #expect(error?.status == .notFound)
            #expect(error?.reason == "Course not found")
        }
    }

    // MARK: - loadCourseForWrite

    @Test func loadCourseForWriteAdmitsAnInstructor() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let prof = try await makeTestUser(on: app, username: "prof")
            try await enroll(prof, in: course, as: .instructor, on: app)
            let req = try request(on: app, params: ["courseID": course.requireID().uuidString], caller: prof)
            let loaded = try await loadCourseForWrite(req, atLeast: .instructor)
            #expect(try loaded.id == course.requireID())
        }
    }

    @Test func loadCourseForWriteRefusesARoleBelowTheFloor() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let assistant = try await makeTestUser(on: app, username: "ta")
            try await enroll(assistant, in: course, as: .ta, on: app)
            let req = try request(on: app, params: ["courseID": course.requireID().uuidString], caller: assistant)
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseForWrite(req, atLeast: .instructor)
            }
            #expect(error?.status == .forbidden)
        }
    }

    @Test func loadCourseForWriteRefusesAnArchivedCourse() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136", archived: true)
            let prof = try await makeTestUser(on: app, username: "prof")
            try await enroll(prof, in: course, as: .instructor, on: app)
            let req = try request(on: app, params: ["courseID": course.requireID().uuidString], caller: prof)
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseForWrite(req, atLeast: .instructor)
            }
            #expect(error?.status == .forbidden)
        }
    }

    @Test func loadCourseForWriteRefusesAMissingCourseBeforeTheRoleCheck() async throws {
        try await withTestApp { app in
            let req = request(on: app, params: ["courseID": UUID().uuidString])
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseForWrite(req, atLeast: .instructor)
            }
            #expect(error?.status == .notFound)
            #expect(error?.reason == "Course not found")
        }
    }

    // MARK: - loadCourseSectionForWrite

    @Test func loadCourseSectionForWriteReturnsASectionOfTheCourse() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let prof = try await makeTestUser(on: app, username: "prof")
            try await enroll(prof, in: course, as: .instructor, on: app)
            let section = APICourseSection(name: "Week 1", sortOrder: 1, courseID: try course.requireID())
            try await section.save(on: app.db)
            let req = try request(on: app, params: ["sectionID": section.requireID().uuidString])
            let loaded = try await loadCourseSectionForWrite(
                req, caller: prof, inCourse: course.requireID(), atLeast: .instructor)
            #expect(try loaded.requireID() == section.requireID())
        }
    }

    @Test func loadCourseSectionForWriteHidesASectionOfAnotherCourse() async throws {
        try await withTestApp { app in
            let mine = try await makeTestCourse(on: app, code: "CS136")
            let other = try await makeTestCourse(on: app, code: "CS246")
            let prof = try await makeTestUser(on: app, username: "prof")
            try await enroll(prof, in: mine, as: .instructor, on: app)
            let section = APICourseSection(name: "Week 1", sortOrder: 1, courseID: try other.requireID())
            try await section.save(on: app.db)
            let req = try request(on: app, params: ["sectionID": section.requireID().uuidString])
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseSectionForWrite(
                    req, caller: prof, inCourse: mine.requireID(), atLeast: .instructor)
            }
            #expect(error?.status == .notFound)
            #expect(error?.reason == "Section not found")
        }
    }

    @Test(arguments: [nil, "not-a-uuid", UUID().uuidString])
    func loadCourseSectionForWriteRefusesWithSectionNotFound(_ parameter: String?) async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let prof = try await makeTestUser(on: app, username: "prof")
            try await enroll(prof, in: course, as: .instructor, on: app)
            let params = parameter.map { ["sectionID": $0] } ?? [:]
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseSectionForWrite(
                    request(on: app, params: params), caller: prof, inCourse: course.requireID(),
                    atLeast: .instructor)
            }
            #expect(error?.status == .notFound)
            #expect(error?.reason == "Section not found")
        }
    }

    @Test func loadCourseSectionForWriteRefusesARoleBelowTheFloor() async throws {
        try await withTestApp { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let assistant = try await makeTestUser(on: app, username: "ta")
            try await enroll(assistant, in: course, as: .ta, on: app)
            let section = APICourseSection(name: "Week 1", sortOrder: 1, courseID: try course.requireID())
            try await section.save(on: app.db)
            let req = try request(on: app, params: ["sectionID": section.requireID().uuidString])
            let error = await #expect(throws: AppError.self) {
                _ = try await loadCourseSectionForWrite(
                    req, caller: assistant, inCourse: course.requireID(), atLeast: .instructor)
            }
            #expect(error?.status == .forbidden)
        }
    }
}
