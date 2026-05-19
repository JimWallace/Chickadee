// Tests/APITests/AssignmentRoutesHelpers.swift
//
// Free-function helpers replacing AssignmentRoutesTestCase.  Tests opt
// in by wrapping their body in `try await withAssignmentRoutesApp { app in ... }`.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

/// Stands up the standard AssignmentRoutes test app and runs the body
/// against it.  Shuts the app down before returning.
func withAssignmentRoutesApp(
    prefix: String = "chickadee-art",
    _ body: (Application) async throws -> Void
) async throws {
    let app = try await makeTestApp(prefix: prefix)
    try await withApp(app, body)
}

// MARK: - Auth helpers

func arLoginAsInstructor(on app: Application) async throws -> String {
    try await loginUser(username: "testinstructor", password: "testpassword", role: "instructor", on: app)
}

func arLoginAsStudent(on app: Application) async throws -> String {
    try await loginUser(username: "teststudent", password: "testpassword", role: "student", on: app)
}

// MARK: - Seeding helpers

@discardableResult
func arInsertSetup(id: String, on app: Application) async throws -> APITestSetup {
    let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
        """
    let courseID = try await app.testCourseID(enrollmentMode: .auto)
    let setup = APITestSetup(
        id: id, manifest: manifest, zipPath: app.testSetupsDirectory + "\(id).zip", courseID: courseID)
    try await setup.save(on: app.db)
    return setup
}

@discardableResult
func arInsertAssignment(
    testSetupID: String,
    title: String,
    isOpen: Bool,
    dueAt: Date? = nil,
    deadlineOverrideActive: Bool = false,
    on app: Application
) async throws -> APIAssignment {
    let courseID = try await app.testCourseID(enrollmentMode: .auto)
    let a = APIAssignment(
        testSetupID: testSetupID,
        title: title,
        dueAt: dueAt,
        isOpen: isOpen,
        deadlineOverrideActive: deadlineOverrideActive,
        courseID: courseID
    )
    try await a.save(on: app.db)
    return a
}

@discardableResult
func arInsertStudent(
    username: String = "student_retest",
    displayName: String? = nil,
    preferredName: String? = nil,
    on app: Application
) async throws -> APIUser {
    let hash = try Bcrypt.hash("testpassword")
    let student = APIUser(
        username: username,
        passwordHash: hash,
        role: "student",
        preferredName: preferredName,
        displayName: displayName
    )
    try await student.save(on: app.db)
    return student
}

@discardableResult
func arInsertUser(
    username: String,
    role: String,
    displayName: String? = nil,
    on app: Application
) async throws -> APIUser {
    let hash = try Bcrypt.hash("testpassword")
    let u = APIUser(
        username: username,
        passwordHash: hash,
        role: role,
        displayName: displayName
    )
    try await u.save(on: app.db)
    return u
}

@discardableResult
func arInsertSubmission(
    id: String,
    testSetupID: String,
    userID: UUID,
    attemptNumber: Int = 1,
    status: String = "complete",
    on app: Application
) async throws -> APISubmission {
    let sub = APISubmission(
        id: id,
        testSetupID: testSetupID,
        zipPath: app.submissionsDirectory + "\(id).zip",
        attemptNumber: attemptNumber,
        status: status,
        userID: userID,
        kind: APISubmission.Kind.student
    )
    try await sub.save(on: app.db)
    return sub
}

func arEnrollStudentInTestCourse(_ student: APIUser, on app: Application) async throws {
    let courseID = try await app.testCourseID(enrollmentMode: .auto)
    let enrollment = APICourseEnrollment(
        userID: try student.requireID(),
        courseID: courseID
    )
    try await enrollment.save(on: app.db)
}

// MARK: - Multipart body builders

func arMultipartAssignmentBody(
    boundary: String,
    csrf: String,
    assignmentName: String,
    assignmentNotebook: String,
    solutionNotebook: String,
    suiteFiles: [(filename: String, contentType: String, content: String)] = [],
    suiteConfig: String? = nil
) -> ByteBuffer {
    var body = ByteBufferAllocator().buffer(capacity: 4096)

    func appendField(_ name: String, _ value: String) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.writeString(value)
        body.writeString("\r\n")
    }

    func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.writeString("Content-Type: \(contentType)\r\n\r\n")
        body.writeBytes(data)
        body.writeString("\r\n")
    }

    appendField("_csrf", csrf)
    appendField("assignmentName", assignmentName)
    appendFile(
        "assignmentNotebookFile",
        filename: "assignment.ipynb",
        data: Data(assignmentNotebook.utf8)
    )
    appendFile(
        "solutionNotebookFile",
        filename: "solution.ipynb",
        data: Data(solutionNotebook.utf8)
    )
    for suiteFile in suiteFiles {
        appendFile(
            "suiteFiles",
            filename: suiteFile.filename,
            contentType: suiteFile.contentType,
            data: Data(suiteFile.content.utf8)
        )
    }
    if let suiteConfig {
        appendField("suiteConfig", suiteConfig)
    }
    body.writeString("--\(boundary)--\r\n")
    return body
}

func arMultipartEditBody(
    boundary: String,
    csrf: String,
    assignmentName: String,
    assignmentNotebook: String,
    solutionNotebook: String,
    suiteConfig: String
) -> ByteBuffer {
    var body = ByteBufferAllocator().buffer(capacity: 4096)

    func appendField(_ name: String, _ value: String) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.writeString(value)
        body.writeString("\r\n")
    }

    func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.writeString("Content-Type: \(contentType)\r\n\r\n")
        body.writeBytes(data)
        body.writeString("\r\n")
    }

    appendField("_csrf", csrf)
    appendField("assignmentName", assignmentName)
    appendFile(
        "assignmentNotebookFile",
        filename: "assignment.ipynb",
        data: Data(assignmentNotebook.utf8)
    )
    appendFile(
        "solutionNotebookFile",
        filename: "solution.ipynb",
        data: Data(solutionNotebook.utf8)
    )
    appendField("suiteConfig", suiteConfig)
    body.writeString("--\(boundary)--\r\n")
    return body
}

func arMultipartBody(
    boundary: String,
    fields: [(String, String)],
    // swiftlint:disable:next large_tuple
    files: [(name: String, filename: String, contentType: String, data: Data)] = []
) -> ByteBuffer {
    var body = ByteBufferAllocator().buffer(capacity: 4096)

    func appendField(_ name: String, _ value: String) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.writeString(value)
        body.writeString("\r\n")
    }

    // swiftlint:disable:next large_tuple
    func appendFile(_ file: (name: String, filename: String, contentType: String, data: Data)) {
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
        body.writeString("Content-Type: \(file.contentType)\r\n\r\n")
        body.writeBytes(file.data)
        body.writeString("\r\n")
    }

    fields.forEach(appendField)
    files.forEach(appendFile)
    body.writeString("--\(boundary)--\r\n")
    return body
}

// MARK: - Zip + notebook fixtures

func arMakeZip(at path: String, entries: [(String, String)]) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("assignment-routes-zip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (name, contents) in entries {
        let fileURL = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = root
    process.arguments = ["-q", "-r", path, "."]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@discardableResult
func arAttachStarterNotebook(
    to setup: APITestSetup,
    bytes: Data,
    on app: Application
) async throws -> String {
    let startersDir = (app.testDataDirectory ?? "") + "starters/"
    try FileManager.default.createDirectory(atPath: startersDir, withIntermediateDirectories: true)
    let starterPath = startersDir + "\(setup.id ?? "x").ipynb"
    try bytes.write(to: URL(fileURLWithPath: starterPath))
    setup.notebookPath = starterPath
    try await setup.save(on: app.db)
    return starterPath
}

func arSeedStudentWorkingCopy(
    setupID: String,
    userID: UUID,
    bytes: Data,
    on app: Application
) throws -> String {
    let path =
        app.directory.publicDirectory
        + "jupyterlite/files/users/\(userID.uuidString.lowercased())/\(setupID)/assignment.ipynb"
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try bytes.write(to: URL(fileURLWithPath: path))
    return path
}
