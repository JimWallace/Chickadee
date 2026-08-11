// APIServer/Utilities/TestScriptTemplates.swift
//
// Python and shell test script templates for the in-browser script editor.
// Templates use the test_runtime builtins injected by the runner:
//   passed(message)                     — exit 0 with short result
//   failed(message)                     — exit 1; multi-line message becomes
//                                         stdout (rendered in longResult) and
//                                         its first line becomes shortResult
//   errored(message)                    — exit 2; same routing as failed()
//   require_function(name[, num_args])  — exit 2 if function is missing or
//                                         has the wrong positional-arg count
//
// When editing, keep these kwargs in sync with `require_function` in
// Sources/Worker/TestRuntimeSources.swift and Tools/runner-support/test_runtime.py
// (enforced by TestScriptTemplatesTests.testTemplates_useOnlyKnownRequireFunctionKwargs).

import Core
import Foundation

// MARK: - Template type enumerations

/// Template types for Python test scripts.
///
/// ONE LEFT, and that is the point. Eight of these duplicated a pattern-family
/// kind that renders in ALL SIX languages, in a strictly better form: a family
/// is server-rendered, spec-hashed, re-renders when a case changes, and is
/// pinned by execution tests, where a template is a one-shot text dump the
/// instructor then owns forever. Offering both taught authors to reach for the
/// fallback.
///
/// | removed | superseded by |
/// |---|---|
/// | `exists` | the automatic existence guard every family emits |
/// | `correctness` | `boundaryEquality` |
/// | `corner_cases` | `boundaryEquality`, several cases |
/// | `exception` | `exceptionExpected` |
/// | `type_check` | `returnTypeCheck` |
/// | `performance` | `performanceThreshold` |
/// | `variable_equality` | `variableEquality` |
/// | `structural_check` | the `astStructure` notebook check |
///
/// `differential` is now superseded too, by `PatternKind.differential` — the
/// ninth kind, which renders in all six languages and computes each case's
/// expected value by running the instructor's reference.
///
/// The template survives it deliberately, and this enum is not empty. Removing
/// it would break every assignment that already applied it: a template is a
/// one-shot text dump the instructor then owns, so their script is a plain
/// authored test with no `generatedBy` link back to here. Nothing would migrate;
/// the option would simply stop being offered while the scripts it wrote kept
/// grading. A new differential test should be a family.
enum PythonTestTemplateType: String, CaseIterable {
    case differential

    var displayName: String {
        switch self {
        case .differential: return "Differential (reference solution)"
        }
    }

    var templateDescription: String {
        switch self {
        case .differential: return "Compares output against an inline reference implementation"
        }
    }
}

/// Template types for shell (`.sh`) test scripts.
enum ShellTestTemplateType: String, CaseIterable {
    case alwaysPass = "always_pass"
    case fileExists = "file_exists"
    case commandOutput = "command_output"

    var displayName: String {
        switch self {
        case .alwaysPass: return "Always Pass (placeholder)"
        case .fileExists: return "File Exists Check"
        case .commandOutput: return "Command Output Check"
        }
    }
}

// MARK: - Python template generation

/// Returns a Python test script for the given template type.
/// `functionName` and `paramNames` are used to personalise the template.
func pythonTestScript(
    type: PythonTestTemplateType,
    functionName: String = "my_function",
    paramNames: [String] = []
) -> String {
    let argList = paramNames.joined(separator: ", ")

    // Wrap the switch in a closure so every case can `return …` while we
    // still prepend a Python shebang to the final result.  Without the
    // shebang, an instructor who saves a test script under a filename
    // that has no `.py` extension (e.g. "beats") falls through to
    // `/bin/sh` on the runner and the Python body blows up as shell.
    // Per v0.4.73 a `#!/usr/bin/env python3` shebang routes the script
    // through the Python runtime regardless of extension.
    let body: String = {
        switch type {

        case .differential:
            let refParams = argList.isEmpty ? "*args, **kwargs" : argList
            return """
                # Test: \(functionName) matches a reference implementation
                #
                # 1. Implement _reference_\(functionName) below.
                # 2. Add test inputs (as tuples) to test_inputs.
                def _reference_\(functionName)(\(refParams)):
                    pass  # TODO: implement reference solution

                test_inputs = []  # TODO: e.g. [(1, 2), (3, 4), ...]
                failures = []
                for args in test_inputs:
                    args = args if isinstance(args, tuple) else (args,)
                    expected = _reference_\(functionName)(*args)
                    actual   = student_module.\(functionName)(*args)
                    if actual != expected:
                        failures.append(f"  \(functionName){args} = {actual!r}, expected {expected!r}")
                if failures:
                    failed("\\n".join(failures))
                else:
                    passed(f"All {len(test_inputs)} case(s) match reference")
                """
        }
    }()
    return "#!/usr/bin/env python3\n" + body
}

// MARK: - Shell template generation

/// Returns a shell test script for the given template type.
/// A shell test-script scaffold, with the assignment's language filled in.
///
/// These three are offered on EVERY language, because `.sh` is the universal
/// test contract — and their bodies named Python: `FILE="solution.py"` and
/// `python3 -c "import solution; …"`. So a non-Python author was handed three
/// templates, all wrong for them, which is worse than being handed none. The
/// filename comes from `sourceFileExtension` and the invocation from
/// `interpreterProbe`, so no new per-language table exists to go stale.
///
/// nil — the author declared NO language — renders in plain shell rather than
/// falling back to Python. A `.sh` suite is the one case where there is no
/// language to name, so the two language-shaped values become ordinary shell
/// variables with a TODO apiece: `FILE` for what the student submits, `RUN` for
/// the command that runs it. That is a scaffold the author completes, where
/// `solution.py` + `python3` was a scaffold they had to notice was wrong first.
///
/// No default on `language:`. The parameter had one, and the scan endpoint
/// omitted the argument — so every author of every language got the Python
/// templates anyway, and the per-language work above never reached a browser.
func shellTestScript(type: ShellTestTemplateType, language: AssignmentLanguage?) -> String {
    // A language names the file it grades; a language-less suite cannot, so the
    // name becomes a placeholder the author replaces — the TODO beside it is
    // already there and now means something.
    let solutionFile = language.map { "solution.\($0.sourceFileExtension)" } ?? "submission"

    switch type {

    case .alwaysPass:
        return """
            #!/bin/sh
            # TODO: replace this placeholder with a real test
            echo "passed"
            exit 0
            """

    case .fileExists:
        return """
            #!/bin/sh
            # Test: a required file exists in the working directory
            FILE="\(solutionFile)"  # TODO: change to the expected filename
            if [ -f "$FILE" ]; then
                echo "File $FILE found"
                exit 0
            else
                echo "File $FILE not found" >&2
                exit 1
            fi
            """

    case .commandOutput:
        return """
            #!/bin/sh
            # Test: the submission's stdout matches an expected value
            EXPECTED="expected output"  # TODO: replace with the expected output
            \(runSubmissionShellFragment(language: language, solutionFile: solutionFile))
            if [ "$ACTUAL" = "$EXPECTED" ]; then
                echo "Output matches"
                exit 0
            else
                printf 'Expected: %s\\nActual:   %s\\n' "$EXPECTED" "$ACTUAL" >&2
                exit 1
            fi
            """
    }
}

/// The shell lines that run the submission and leave its output in `$ACTUAL`.
///
/// Three shapes. The two language ones are chosen by
/// `capabilityRequiresExecutableOutput` — the fact that already means "grading
/// this language builds something before running it". Asking it here rather
/// than switching on `.cpp` keeps the one judgement in one place; a seventh
/// compiled language gets the compile form for free.
///
/// The third is for an assignment that declares no language, where there is no
/// interpreter to name and guessing `python3` would be a guess the author has
/// to catch. It spends two shell variables instead — the same currency the rest
/// of the template is written in — so what has to be decided is visible as a
/// TODO rather than buried in a plausible-looking command.
private func runSubmissionShellFragment(
    language: AssignmentLanguage?, solutionFile: String
) -> String {
    guard let language else {
        return """
            FILE="\(solutionFile)"  # TODO: set to the filename students submit
            RUN="./$FILE"  # TODO: set to the command that runs the submission
            ACTUAL=$($RUN 2>&1)
            """
    }
    // `scriptRunCommand`, not `interpreterProbe.command`. The two agree for
    // every language but R, where the probe is `R` and the runner spawns
    // `Rscript` — and `R solution.R` does not run the file, it warns that the
    // argument is ignored and waits on stdin. So every R author's scaffold was
    // a command that cannot work.
    let interpreter = language.descriptor.scriptRunCommand
    guard language.descriptor.capabilityRequiresExecutableOutput else {
        // Run the file directly. This replaced a Python-only
        // `python3 -c "import solution; print(solution.main())"`, which had no
        // general form — and running the submission and comparing its stdout is
        // the more common shape anyway.
        return #"ACTUAL=$(\#(interpreter) \#(solutionFile) 2>&1)"#
    }
    return """
        \(interpreter) -O2 -o ./ck_solution \(solutionFile) || { echo "Compilation failed" >&2; exit 2; }
        ACTUAL=$(./ck_solution 2>&1)
        """
}

// MARK: - JSON representation for the browser

/// Lightweight description of a template type, used to populate the template
/// picker in the browser.
struct TestTemplateInfo: Codable {
    let id: String
    let displayName: String
    let description: String
    let language: String  // "python" | "shell"
    let content: String
}

/// Returns all template types as `TestTemplateInfo` values for the given function.
/// Used by the scan-notebook and template-picker endpoints.
/// No default on `language:` — the scan endpoint omitted the argument, which is
/// how the shell templates stayed Python for every assignment in every language
/// long after they learned to render per-language.
func allTemplateInfos(
    functionName: String, paramNames: [String], language: AssignmentLanguage?
) -> [TestTemplateInfo] {
    let pyTypes = PythonTestTemplateType.allCases.map { t in
        TestTemplateInfo(
            id: t.rawValue,
            displayName: t.displayName,
            description: t.templateDescription,
            language: "python",
            content: pythonTestScript(type: t, functionName: functionName, paramNames: paramNames)
        )
    }
    let shTypes = ShellTestTemplateType.allCases.map { t in
        TestTemplateInfo(
            id: t.rawValue,
            displayName: t.displayName,
            description: t.displayName,
            language: "shell",
            content: shellTestScript(type: t, language: language)
        )
    }
    return pyTypes + shTypes
}
