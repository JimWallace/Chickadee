import XCTest
@testable import chickadee_server
import Core

final class AssignmentHelpersTests: XCTestCase {

    func testSanitizedAssignmentReturnPathAcceptsOnlyInstructorScopedPaths() {
        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/asg123/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/submissions"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "/instructor/other/submissions",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/edit"
        )

        XCTAssertEqual(
            sanitizedAssignmentReturnPath(
                "https://example.com/escape",
                assignmentIDRaw: "asg123",
                fallbackPath: "/instructor/asg123/edit"
            ),
            "/instructor/asg123/edit"
        )
    }

    func testNotebookFilenameForStorageSanitizesAndNormalizesExtension() {
        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "../Unit 1: Intro", fallback: "assignment.ipynb"),
            "Unit 1  Intro.ipynb"
        )

        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "lesson.ipynb", fallback: "assignment.ipynb"),
            "lesson.ipynb"
        )

        XCTAssertEqual(
            notebookFilenameForStorage(uploadedName: "   ", fallback: "starter.ipynb"),
            "starter.ipynb"
        )
    }

    func testManifestDependentsReturnsScriptsThatReferenceDependency() {
        let manifest = try! makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 2,
                    displayName: "Release"
                ),
                ConfiguredSuiteEntry(
                    script: "03_secret.py",
                    tier: "secret",
                    order: 3,
                    dependsOn: ["01_public.py"],
                    points: 3,
                    displayName: nil
                )
            ],
            includeMakefile: false
        )

        XCTAssertEqual(
            manifestDependents(manifestJSON: manifest, filename: "01_public.py"),
            ["02_release.py", "03_secret.py"]
        )
        XCTAssertEqual(manifestDependents(manifestJSON: manifest, filename: "missing.py"), [])
    }

    func testUpdateManifestAddingScriptPreservesMetadataAndAppendsEntry() throws {
        let original = """
        {
          "schemaVersion": 1,
          "gradingMode": "browser",
          "requiredFiles": [],
          "testSuites": [
            {"tier": "public", "script": "01_public.py"}
          ],
          "timeLimitSeconds": 10,
          "makefile": {"target": null},
          "starterNotebook": "starter.ipynb"
        }
        """

        let updated = try XCTUnwrap(
            updateManifestAddingScript(
                manifestJSON: original,
                entry: ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 99,
                    dependsOn: ["01_public.py"],
                    points: 2,
                    displayName: "Release tests"
                )
            )
        )

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        XCTAssertEqual(props.gradingMode, .browser)
        XCTAssertEqual(props.starterNotebook, "starter.ipynb")
        XCTAssertNotNil(props.makefile)
        XCTAssertEqual(props.testSuites.map(\.script), ["01_public.py", "02_release.py"])
        XCTAssertEqual(props.testSuites.last?.dependsOn, ["01_public.py"])
        XCTAssertEqual(props.testSuites.last?.points, 2)
        XCTAssertEqual(props.testSuites.last?.name, "Release tests")
    }

    func testUpdateManifestRemovingScriptClearsDependencyReferences() throws {
        let original = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 1,
                    displayName: nil
                )
            ],
            includeMakefile: false
        )

        let updated = try XCTUnwrap(
            updateManifestRemovingScript(manifestJSON: original, filename: "01_public.py")
        )

        let props = try JSONDecoder().decode(TestProperties.self, from: Data(updated.utf8))
        XCTAssertEqual(props.testSuites.map(\.script), ["02_release.py"])
        XCTAssertEqual(props.testSuites.first?.dependsOn, [])
    }

    func testMakeWorkerManifestJSONTopologicallySortsSuitesAndOmitsDefaults() throws {
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "03_secret.py",
                    tier: "secret",
                    order: 3,
                    dependsOn: ["02_release.py"],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "01_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                ),
                ConfiguredSuiteEntry(
                    script: "02_release.py",
                    tier: "release",
                    order: 2,
                    dependsOn: ["01_public.py"],
                    points: 4,
                    displayName: "Release tests"
                )
            ],
            includeMakefile: true,
            gradingMode: "worker",
            starterNotebook: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
        )
        let suites = try XCTUnwrap(object["testSuites"] as? [[String: Any]])

        XCTAssertEqual(suites.map { $0["script"] as? String }, ["01_public.py", "02_release.py", "03_secret.py"])
        XCTAssertNil(object["starterNotebook"])
        XCTAssertNotNil(object["makefile"])
        XCTAssertNil(suites[0]["points"], "Default weight should be omitted")
        XCTAssertNil(suites[0]["dependsOn"], "Empty dependencies should be omitted")
        XCTAssertEqual(suites[1]["points"] as? Int, 4)
        XCTAssertEqual(suites[1]["name"] as? String, "Release tests")
    }
}
