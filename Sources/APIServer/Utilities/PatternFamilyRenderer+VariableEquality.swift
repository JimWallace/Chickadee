// APIServer/Utilities/PatternFamilyRenderer+VariableEquality.swift
//
// `.variableEquality` renderer.  Split from PatternFamilyRenderer.swift
// (June 2026 audit); byte-identical output.

import Core

// MARK: - variableEquality

/// Renders a single-variable equality check.  `family.functionName` and
/// `family.paramNames` are ignored for this kind — the variable name lives
/// in `case.args[0]` (validated by `ManifestValidation` to be a non-empty
/// string) and the expected value in `case.expected`.  A sentinel default
/// on `getattr` distinguishes "not defined at all" from "defined as None"
/// so students get a useful error message in both cases.
func renderVariableEquality(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    // Section + family variables are declared as module-level globals in
    // the generated test.  `variableEquality` is checking a STUDENT-module
    // attribute (not a declared-in-this-file one), so the section/family
    // variables don't interact with the check itself — but we still emit
    // them so the Variables row (e.g. a shared `patients` list) is
    // available if a future kind / hint references it.
    _ = sectionVariables  // currently unused by this kind; keep the signature consistent
    // Validation guarantees args.count == 1 and args[0] is a non-empty
    // string, but fall back to a sentinel name if somehow absent so the
    // generated Python is still syntactically valid.
    let variableName: String = {
        guard let first = c.args.first, case .string(let name) = first else {
            return "<unset>"
        }
        return name
    }()
    let nameLiteral = "\"" + escapeForPythonStringLiteral(variableName) + "\""

    // A per-student `expectedVarRef` is bound at grading time from
    // `_ck_inputs.py`; see personalizationPreambleForCase.  Note the variable
    // NAME (args[0]) stays a baked literal — only the expected VALUE
    // personalizes, which is why the validator still rejects arg refs here.
    // With no per-student refs the preamble is "" and `expectedExpression`
    // returns the same literal as before, so existing families render
    // byte-identically and their spec_hash / TestSetupCache keys don't churn.
    let preamble = personalizationPreambleForCase(c, perStudentNames: perStudentNames)
    let preambleBlock = preamble.isEmpty ? "" : preamble + "\n\n"

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        \(preambleBlock)variable_name = \(nameLiteral)
        expected      = \(expectedExpression(for: c))

        _MISSING = object()
        actual = getattr(student_module, variable_name, _MISSING)
        if actual is _MISSING:
            failed(
                f"Variable `{variable_name}` is not defined\\n"
                f"\(GeneratedMessage.expected){expected!r}\\n"            )

        if actual != expected:
            failed(
                f"Variable `{variable_name}` has the \(GeneratedMessage.wrongValue)\\n"
                f"\(GeneratedMessage.expected){expected!r}\\n"
                f"\(GeneratedMessage.got){actual!r}\\n"            )

        passed(f"{variable_name} == {actual!r}")
        """
}
