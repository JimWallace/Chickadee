// APIServer/Utilities/PatternKindHandler.swift
//
// Per-kind behaviour for `PatternKind`, captured behind one protocol with a
// single conforming type per case.  Replaces the parallel `switch family.kind`
// sites that used to live in `PatternFamilyRenderer` (render dispatch) and
// `PatternFamilyValidator` (per-case validation, the functionName exemption,
// and the approximate-tolerance rule) — adding or changing a kind now means
// touching one handler plus the `patternKindHandler(for:)` resolver, and a new
// `PatternKind` case fails to compile until the resolver's exhaustive switch
// gains an entry.
//
// The `PatternKind` enum stays the Codable wire format unchanged; these
// handlers are pure dispatch and never serialised.  Render bodies still live
// in `PatternFamilyRenderer.swift` (they share private template helpers);
// each handler delegates to the matching `render*` function so generated
// script bytes — and therefore every `spec_hash` and `TestSetupCache` key —
// stay identical.

import Core
import Vapor

/// Behaviour for one `PatternKind`: how a case renders to Python and how a
/// family/case is validated before it is applied to a test setup.
protocol PatternKindHandler: Sendable {
    /// Whether this kind requires `PatternFamily.functionName` to be a valid
    /// Python identifier.  `false` for kinds that inspect module-level state
    /// rather than calling a function (`.variableEquality`).
    var requiresFunctionName: Bool { get }

    /// Renders one enabled case to Python source.  Delegates to the matching
    /// `render*` function in `PatternFamilyRenderer.swift`.
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String

    /// Family-level validation (e.g. tolerance bounds).  Default: no-op.
    func validateFamily(_ family: PatternFamily) throws

    /// Validates the `args` / `expected` shape of a single case against this
    /// kind's contract.
    func validateCase(family: PatternFamily, case c: PatternCase) throws
}

extension PatternKindHandler {
    var requiresFunctionName: Bool { true }
    func validateFamily(_ family: PatternFamily) throws {}
}

/// Resolves a `PatternKind` to its handler.  The exhaustive switch is the
/// single dispatch point: a new enum case fails to compile here until a
/// handler is wired in, restoring the compile-time guarantee the per-site
/// `switch family.kind` statements used to provide.
func patternKindHandler(for kind: PatternKind) -> any PatternKindHandler {
    switch kind {
    case .boundaryEquality: return BoundaryEqualityKind()
    case .approximateEquality: return ApproximateEqualityKind()
    case .variableEquality: return VariableEqualityKind()
    case .returnTypeCheck: return ReturnTypeCheckKind()
    case .exceptionExpected: return ExceptionExpectedKind()
    case .performanceThreshold: return PerformanceThresholdKind()
    case .stdoutEquality: return StdoutEqualityKind()
    }
}

// MARK: - Shared validation helper

/// The arg-count check shared by every function-calling kind: when the family
/// declares parameter names, each case must supply exactly that many args.
/// `kindLabel`, when set, is interpolated as a `(kind_name)` infix so the
/// error message matches the historical per-kind wording.
private func validatePatternArgCount(
    family: PatternFamily, case c: PatternCase, kindLabel: String?
) throws {
    guard !family.paramNames.isEmpty, c.args.count != family.paramNames.count else { return }
    let prefix = "Pattern family '\(family.id)'" + (kindLabel.map { " (\($0))" } ?? "")
    throw Abort(
        .unprocessableEntity,
        reason:
            "\(prefix): case '\(c.key)' has \(c.args.count) arg(s) but family declares \(family.paramNames.count) parameter(s)"
    )
}

// MARK: - boundaryEquality

struct BoundaryEqualityKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderBoundaryEquality(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: nil)
    }
}

// MARK: - approximateEquality

struct ApproximateEqualityKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderApproximateEquality(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateFamily(_ family: PatternFamily) throws {
        if let tol = family.defaults.tolerance, tol < 0 || !tol.isFinite {
            throw Abort(
                .unprocessableEntity,
                reason: "Pattern family '\(family.id)': tolerance must be a non-negative finite number.")
        }
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: nil)
    }
}

// MARK: - variableEquality

struct VariableEqualityKind: PatternKindHandler {
    var requiresFunctionName: Bool { false }

    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderVariableEquality(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        // Exactly one arg, which must be a non-empty string naming
        // the module-level variable to check.  `paramNames` is
        // ignored — for this kind it's purely a UI hint (column
        // header), not something the renderer or validator cares
        // about.
        guard c.args.count == 1 else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' must have exactly one arg (the variable name); got \(c.args.count)"
            )
        }
        guard case .string(let varName) = c.args[0],
            !varName.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' arg must be a non-empty string (the variable name)"
            )
        }
        guard isValidPythonIdentifier(varName) else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (variable_equality): case '\(c.key)' variable name '\(varName)' is not a valid Python identifier"
            )
        }
    }
}

// MARK: - returnTypeCheck

struct ReturnTypeCheckKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderReturnTypeCheck(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: "return_type_check")
        guard case .string(let expectedType) = c.expected,
            !expectedType.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (return_type_check): case '\(c.key)' expected must be a non-empty string naming the type (e.g. \"int\", \"DataFrame\")"
            )
        }
    }
}

// MARK: - exceptionExpected

struct ExceptionExpectedKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderExceptionExpected(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: "exception_expected")
        guard case .string(let exceptionType) = c.expected,
            !exceptionType.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (exception_expected): case '\(c.key)' expected must be a non-empty string naming the exception class (e.g. \"ValueError\")"
            )
        }
    }
}

// MARK: - performanceThreshold

struct PerformanceThresholdKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderPerformanceThreshold(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: "performance_threshold")
        let threshold: Double? = {
            switch c.expected {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return nil
            }
        }()
        guard let t = threshold, t.isFinite, t > 0 else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (performance_threshold): case '\(c.key)' expected must be a positive number (milliseconds)"
            )
        }
    }
}

// MARK: - stdoutEquality

struct StdoutEqualityKind: PatternKindHandler {
    func render(
        family: PatternFamily, case c: PatternCase,
        sectionVariables: [FamilyVariable], specHash: String
    ) -> String {
        renderStdoutEquality(family: family, case: c, sectionVariables: sectionVariables, specHash: specHash)
    }

    func validateCase(family: PatternFamily, case c: PatternCase) throws {
        try validatePatternArgCount(family: family, case: c, kindLabel: "stdout_equality")
        // Empty string is intentionally allowed — it means "this
        // function should print nothing", a legitimate case for
        // a beginner exercise where the assignment is to add the
        // print() call.
        guard case .string = c.expected else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Pattern family '\(family.id)' (stdout_equality): case '\(c.key)' expected must be a string (the captured stdout to match)"
            )
        }
    }
}
