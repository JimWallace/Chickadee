import Core
import Testing

@testable import APIServer

/// The browser runner needs the assignment's language to pick which per-student
/// inputs file to write into the grading workspace — `_ck_inputs.py` or
/// `_ck_inputs.R` (#1271). It learns it from the seed endpoint, because the
/// server already resolves it there with `AssignmentLanguage.resolve` in order
/// to render each personalization value as a literal in the right language.
///
/// The browser then builds that file in JavaScript
/// (`personalizationInputsSourceR` in `Public/r-grading-shared.js`), which makes
/// it a second implementation of `AssignmentLanguage.renderInputsFile(.r)`. This
/// suite pins the two together: the expectations below are the exact strings the
/// JS asserts in `Tests/BrowserRunnerJSTests/r-grading-shared.test.mjs`, so a
/// change to either side that is not mirrored fails here.
@Suite struct BrowserRunnerSeedLanguageTests {

    @Test func rInputsFileMatchesTheBrowserRendering() {
        let rendered = AssignmentLanguage.r.renderInputsFile([
            "threshold": "42",
            "alpha": "c(1, 2)",
        ])
        #expect(
            rendered == """
                # Auto-generated per-student grading inputs (issue #461). Do not edit.
                .ck_inputs <- list(
                    `alpha` = c(1, 2),
                    `threshold` = 42
                )

                """)
    }

    @Test func emptyRInputsFileMatchesTheBrowserRendering() {
        #expect(
            AssignmentLanguage.r.renderInputsFile([:]) == """
                # Auto-generated per-student grading inputs (issue #461). Do not edit.
                .ck_inputs <- list()

                """)
    }

    @Test func pythonInputsFileIsUnchangedByTheRAddition() {
        // The Python branch is the one every existing browser-graded assignment
        // takes; #1271 must not have moved a byte of it.
        #expect(
            AssignmentLanguage.python.renderInputsFile(["threshold": "42"]) == """
                # Auto-generated per-student grading inputs (issue #461). Do not edit.
                _ck = {
                    "threshold": 42,
                }

                """)
    }

    /// The wire value the browser compares against: `browser-runner.js` treats
    /// exactly `"r"` as R and anything else (including a missing field, from a
    /// server that predates this) as Python, so the raw values must not drift.
    @Test(arguments: [(AssignmentLanguage.python, "python"), (AssignmentLanguage.r, "r")])
    func languageRawValuesAreTheBrowserWireValues(language: AssignmentLanguage, expected: String) {
        #expect(language.rawValue == expected)
    }

    @Test func seedResponseCarriesTheLanguage() throws {
        let response = BrowserRunnerSeedResponse(
            seed: "deadbeef", personalizedInputs: ["threshold": "42"],
            personalizedFiles: nil, language: AssignmentLanguage.r.rawValue)
        #expect(response.language == "r")

        // Nil is the "no assignment owns this setup" case — the same one that
        // yields a nil seed, where there is nothing personalized to deliver.
        let empty = BrowserRunnerSeedResponse(
            seed: nil, personalizedInputs: nil, personalizedFiles: nil, language: nil)
        #expect(empty.language == nil)
    }
}
