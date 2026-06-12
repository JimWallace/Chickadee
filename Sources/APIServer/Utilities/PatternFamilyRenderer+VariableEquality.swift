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
    specHash: String
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

    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        variable_name = \(nameLiteral)
        expected      = \(c.expected.pythonLiteral)

        _MISSING = object()
        actual = getattr(student_module, variable_name, _MISSING)
        if actual is _MISSING:
            failed(
                f"Variable `{variable_name}` is not defined\\n"
                f"  expected: {expected!r}\\n"            )

        if actual != expected:
            failed(
                f"Variable `{variable_name}` has the wrong value\\n"
                f"  expected: {expected!r}\\n"
                f"  got:      {actual!r}\\n"            )

        passed(f"{variable_name} == {actual!r}")
        """
}
