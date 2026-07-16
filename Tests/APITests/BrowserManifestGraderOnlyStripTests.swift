import Foundation
import Testing

@testable import APIServer

/// Pins the contract for `manifestWithGraderOnlyFilesStripped`: the
/// browser-runner manifest endpoint must not leak grader-only support-file
/// names (option B — `docs/datasets.md`) to the student's browser, while
/// leaving every other field — and the common no-grader-only case — untouched.
@Suite struct BrowserManifestGraderOnlyStripTests {

    @Test func blanksGraderOnlyNamesAndPreservesOtherFields() throws {
        let manifest =
            #"{"schemaVersion":1,"graderOnlyFiles":["holdout.csv","answers.py"],"requiredFiles":["warmup.py"]}"#

        let stripped = manifestWithGraderOnlyFilesStripped(manifest)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any])
        #expect(try #require(object["graderOnlyFiles"] as? [String]).isEmpty)
        // The names must be gone from the served bytes, not just the parsed array.
        #expect(!stripped.contains("holdout.csv"))
        #expect(!stripped.contains("answers.py"))
        // Every other field is preserved.
        #expect(try #require(object["requiredFiles"] as? [String]) == ["warmup.py"])
        #expect(try #require(object["schemaVersion"] as? Int) == 1)
    }

    @Test func noOpWhenGraderOnlyArrayIsEmpty() {
        // The common case: the field exists but is empty — return byte-for-byte
        // so non-grader-only assignments are unchanged (no JSON re-encode).
        let manifest = #"{"schemaVersion":1,"graderOnlyFiles":[],"requiredFiles":["warmup.py"]}"#
        #expect(manifestWithGraderOnlyFilesStripped(manifest) == manifest)
    }

    @Test func noOpWhenGraderOnlyKeyAbsent() {
        // Legacy manifests authored before the field existed.
        let manifest = #"{"schemaVersion":1,"requiredFiles":["warmup.py"]}"#
        #expect(manifestWithGraderOnlyFilesStripped(manifest) == manifest)
    }

    @Test func noOpOnNonJSONBody() {
        let garbage = "this is not json"
        #expect(manifestWithGraderOnlyFilesStripped(garbage) == garbage)
    }
}
