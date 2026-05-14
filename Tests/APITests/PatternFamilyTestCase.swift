// Tests/APITests/PatternFamilyTestCase.swift
//
// Shared base class for the PatternFamily test suite.  Subclasses focus
// on one concern (Renderer/Validation, Apply, Sections, Kinds) so XCTest
// --parallel can spread them across workers.

import Core
import Crypto
import Fluent
import Foundation
import Vapor
import XCTest

@testable import chickadee_server

class PatternFamilyTestCase: XCTestCase {

    // MARK: - Family fixtures

    func bmiFamily(
        id: String = "bmi_category",
        hint: String? = "values below 18.5 should be 'underweight'",
        tier: TestTier = .pub
    ) -> PatternFamily {
        PatternFamily(
            id: id,
            name: "BMI Category Boundaries",
            kind: .boundaryEquality,
            functionName: "bmi_category",
            paramNames: ["bmi"],
            defaults: PatternDefaults(tier: tier, points: 1, hint: hint),
            cases: [
                PatternCase(
                    key: "01", label: "BMI < 18.5 is underweight",
                    args: [.double(18.49)], expected: .string("underweight")),
                PatternCase(
                    key: "02", label: "BMI = 18.5 is normal",
                    args: [.double(18.5)], expected: .string("normal")),
                PatternCase(
                    key: "03", label: "BMI >= 30 is obese",
                    args: [.double(30.0)], expected: .string("obese")),
            ]
        )
    }

    func approxFamily(tolerance: Double? = 0.01) -> PatternFamily {
        PatternFamily(
            id: "bmi_kg_m2",
            name: "BMI numeric",
            kind: .approximateEquality,
            functionName: "bmi",
            paramNames: ["mass_kg", "height_m"],
            defaults: PatternDefaults(tier: .pub, points: 1, hint: nil, tolerance: tolerance),
            cases: [
                PatternCase(
                    key: "01", label: "average adult",
                    args: [.double(70.0), .double(1.75)], expected: .double(22.857)),
                PatternCase(
                    key: "02", label: "tall adult",
                    args: [.double(85.0), .double(1.90)], expected: .double(23.546)),
            ]
        )
    }

    func notebookVariablesFamily() -> PatternFamily {
        PatternFamily(
            id: "notebook_variables",
            name: "Notebook Variables",
            kind: .variableEquality,
            functionName: "_",
            paramNames: ["variable"],
            defaults: PatternDefaults(
                tier: .pub, points: 1, hint: "Make sure you assigned the value to the variable with this exact name."),
            cases: [
                PatternCase(
                    key: "01", label: "beats equals 5",
                    args: [.string("beats")], expected: .int(5)),
                PatternCase(
                    key: "02", label: "note_name equals A",
                    args: [.string("note_name")], expected: .string("A")),
            ]
        )
    }

    func helloPrintsFamily(expected: String = "hi world") -> PatternFamily {
        PatternFamily(
            id: "hello_prints",
            name: "Hello prints to stdout",
            kind: .stdoutEquality,
            functionName: "say_hi",
            paramNames: ["name"],
            cases: [
                PatternCase(
                    key: "01", label: "prints greeting",
                    args: [.string("world")], expected: .string(expected))
            ]
        )
    }

    // MARK: - Fixture plumbing

    struct Fixture {
        let app: Application
        let setup: APITestSetup
        let cleanup: () -> Void
    }

    func makeFixture() async throws -> Fixture {
        let app = try await Application.make(.testing)
        try await configureTestDatabase(app)

        let tmpDir = NSTemporaryDirectory() + "pattern-family-tests-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        app.testSetupsDirectory = tmpDir

        let courseID = UUID()
        let course = APICourse(id: courseID, code: "PF101", name: "Pattern Family Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let zipPath = tmpDir + "\(UUID().uuidString).zip"
        try writeEmptyZip(at: zipPath)

        let initialManifest = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false
        )
        let setup = APITestSetup(
            id: "pf_test_\(UUID().uuidString.prefix(8))",
            manifest: initialManifest, zipPath: zipPath, courseID: courseID
        )
        try await setup.save(on: app.db)

        let appBox = app
        return Fixture(
            app: app, setup: setup,
            cleanup: {
                try? FileManager.default.removeItem(atPath: tmpDir)
                Task { try? await appBox.asyncShutdown() }
            })
    }

    func writeEmptyZip(at path: String) throws {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("empty-zip-staging-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }
        // zip needs at least one entry to produce a valid archive.
        try Data("placeholder".utf8).write(
            to: stagingDir.appendingPathComponent(".placeholder")
        )
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stagingDir
        zip.arguments = ["-q", "-r", path, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
    }

    func manifestCacheMaterial(_ setup: APITestSetup) throws -> String {
        // Mirror the shape the runner uses at RunnerDaemon.swift:1110-1116:
        //   hash(testSetupID + url + manifestBytes)
        // Using manifest bytes alone is enough to prove invalidation here.
        let digest = SHA256.hash(data: Data(setup.manifest.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func decodeManifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    func assertValidPythonSyntax(
        _ source: String, label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]
        let stdin = Pipe(); let stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(source.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail(
                "Generated source for \(label) is not valid Python:\n\(err)\n--- source ---\n\(source)",
                file: file, line: line)
        }
    }
}
