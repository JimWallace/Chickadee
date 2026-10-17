// Tests/APITests/TestManifests.swift
//
// The `test.properties.json` manifests that many suites build a setup from.
// Each was once a raw-string literal repeated in six or more files; a change
// to the manifest format then meant finding every copy.
//
// Name a manifest here when a second file needs the same bytes. A manifest
// that one test is about (a malformed one, a pattern family, a language
// declaration under test) stays in that test, where the reader can see it.

enum TestManifests {
    /// No grading mode, no suites.
    static let emptySuite = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Worker-graded, no suites.
    static let workerEmpty = #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#

    /// Worker-graded, no suites, with the optional fields written out.
    static let workerEmptyExplicit =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#

    /// Worker-graded, one public Python suite named `tests.py`.
    static let workerOnePythonSuite =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#

    /// Browser-graded, no suites.
    static let browserEmpty = #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#

    /// Declared Python, no suites.
    static let pythonDeclaredEmpty =
        #"{"schemaVersion":1,"language":"python","languageDeclared":true,"testSuites":[],"timeLimitSeconds":10}"#
}
