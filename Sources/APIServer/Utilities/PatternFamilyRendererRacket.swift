// APIServer/Utilities/PatternFamilyRendererRacket.swift
//
// The Racket half of the pattern-family renderer: every `PatternKind` rendered
// as a `.rkt` test script.
//
// Structured like PatternFamilyRendererLua.swift — one switch over the kinds,
// small bodies, a shared call-context helper — and reading its student-facing
// wording from `GeneratedMessage` rather than restating it.
//
// THE ONE THING THAT MAKES RACKET DIFFERENT FROM THE OTHER FIVE.
// A generated test never `require`s the submission. An HtDP teaching-language
// module (`#lang htdp/bsl`, what CS 135/115 write) exports nothing, so a
// `require` binds nothing at all — silently. Every body below goes through the
// runtime's three-step access instead: `chickadee-load-student` for a namespace,
// `chickadee-defined?` to test a binding, `chickadee-call` to apply one. The
// full reasoning, with the measurements behind each step, is in the header of
// `Tools/runner-support/test_runtime.rkt`.
//
// The generated test is always `#lang racket/base` even when the submission is
// BSL, which is what lets one rendered file grade both dialects: the test gets
// full-Racket syntax, the submission keeps its own semantics, and neither
// constrains the other.
//
// GAPS ARE DROPPED, NOT PASSED AS A HOLE. Lua renders an omitted argument as a
// positional `nil` because that is how Lua spells a default. Racket has no such
// notion — BSL has no optional parameters at all — so an omitted argument is
// simply not passed, and an arity error surfaces as an ordinary test failure.

import Core
import Foundation

// MARK: - Header

private func racketGeneratedCaseHeader(
    family: PatternFamily, case c: PatternCase, specHash: String
) -> String {
    let label = c.label.isEmpty ? "\(family.functionName) case \(c.key)" : c.label
    return """
        ; Test: \(racketComment(label))
        ; Generated from pattern family "\(racketComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
        """
}

/// Strips anything that would end the `; Test:` line the runner reads the label
/// from. Newlines only — a comment cannot be escaped out of.
func racketComment(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

// MARK: - Call context

struct RacketCallContext {
    /// `(define name <literal>)` lines, or "" when the case takes no arguments.
    let declBlock: String
    /// The argument list as a Racket list expression: `(list a b)` / `(list)`.
    let argList: String
    /// Fragment for the `input:` line of a failure message.
    let inputPreview: String
}

func racketCallContext(for family: PatternFamily, case c: PatternCase) -> RacketCallContext {
    let argNames: [String] = {
        if !family.paramNames.isEmpty { return family.paramNames }
        return c.args.indices.map { "arg-\($0 + 1)" }
    }()
    let provided: [Bool] = {
        guard !c.argsProvided.isEmpty else { return Array(repeating: true, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argsProvided.count ? c.argsProvided[i] : true }
    }()
    let varRefs: [String?] = {
        guard !c.argVarRefs.isEmpty else { return Array(repeating: nil, count: argNames.count) }
        return (0..<argNames.count).map { i in i < c.argVarRefs.count ? c.argVarRefs[i] : nil }
    }()

    var declLines: [String] = []
    var callParts: [String] = []
    var previewParts: [String] = []
    for (idx, name) in argNames.enumerated() {
        guard idx < provided.count ? provided[idx] : true else { continue }
        let local = racketArgumentName(name)
        if let refName = idx < varRefs.count ? varRefs[idx] : nil {
            declLines.append("(define \(local) \(racketArgumentName(refName)))")
        } else if idx < c.args.count {
            declLines.append("(define \(local) \(c.args[idx].racketLiteral))")
        } else {
            continue
        }
        callParts.append(local)
        previewParts.append("\"\(name)=\" (chickadee-format \(local))")
    }
    return RacketCallContext(
        declBlock: declLines.joined(separator: "\n"),
        argList: callParts.isEmpty ? "(list)" : "(list " + callParts.joined(separator: " ") + ")",
        inputPreview: previewParts.isEmpty
            ? "\"(no arguments)\"" : "(string-append " + previewParts.joined(separator: " \" \" ") + ")"
    )
}

/// Author-chosen names reach source here, and Racket's identifier grammar is
/// permissive enough that almost anything passes — but a name carrying a reader
/// delimiter would end the identifier early and corrupt the rest of the form.
/// Such names are already refused at save time; this is the backstop, and it
/// renders an obviously-wrong identifier rather than plausible source.
func racketArgumentName(_ name: String) -> String {
    isValidRacketIdentifier(name) ? name : "ck-invalid-name"
}

// MARK: - Per-case rendering

/// Renders one enabled case of `family` as a Racket test script.
func renderRacketPatternCase(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String,
    perStudentNames: Set<String> = []
) -> String {
    let header = racketGeneratedCaseHeader(family: family, case: c, specHash: specHash)
    let variableBlock = TestScriptVariablePrepender.emit(
        sectionVariables + family.variables, language: .racket)
    let preamble = racketPersonalizationPreamble(c, perStudentNames: perStudentNames)
    let prelude = [
        header,
        "#lang racket/base",
        "(require \"test_runtime.rkt\")",
        variableBlock,
        preamble,
    ].filter { !$0.isEmpty }.joined(separator: "\n\n")

    switch family.kind {
    case .boundaryEquality:
        return racketEqualityCase(family: family, case: c, prelude: prelude, unordered: false)
    case .unorderedEquality:
        return racketEqualityCase(family: family, case: c, prelude: prelude, unordered: true)
    case .approximateEquality:
        return racketApproximateCase(family: family, case: c, prelude: prelude)
    case .variableEquality:
        return racketVariableEqualityCase(family: family, case: c, prelude: prelude)
    case .returnTypeCheck:
        return racketReturnTypeCase(family: family, case: c, prelude: prelude)
    case .exceptionExpected:
        return racketExceptionCase(family: family, case: c, prelude: prelude)
    case .performanceThreshold:
        return racketPerformanceCase(family: family, case: c, prelude: prelude)
    case .stdoutEquality:
        return racketStdoutCase(family: family, case: c, prelude: prelude)
    case .differential:
        return racketDifferentialCase(family: family, case: c, prelude: prelude)
    }
}

/// Binds each per-student input referenced by this case to a local, so the case
/// bodies read the same whether a value is a literal or a `$name` reference.
private func racketPersonalizationPreamble(
    _ c: PatternCase, perStudentNames: Set<String>
) -> String {
    var names: [String] = []
    for ref in c.argVarRefs.compactMap({ $0 }) where perStudentNames.contains(ref) {
        names.append(ref)
    }
    if let expectedRef = c.expectedVarRef, perStudentNames.contains(expectedRef) {
        names.append(expectedRef)
    }
    guard !names.isEmpty else { return "" }
    var seen = Set<String>()
    let lines = names.filter { seen.insert($0).inserted }.map {
        "(define \(racketArgumentName($0)) (hash-ref (chickadee-inputs) \(JSONValue.string($0).racketLiteral) #f))"
    }
    return lines.joined(separator: "\n")
}

/// The expected value: a per-student reference when the case names one,
/// otherwise the authored literal.
private func racketExpected(_ c: PatternCase) -> String {
    if let ref = c.expectedVarRef, !ref.isEmpty { return racketArgumentName(ref) }
    return c.expected.racketLiteral
}

private func racketLoadAndGuard(_ family: PatternFamily) -> String {
    """
    (define ns (chickadee-load-student))
    (unless (chickadee-defined? ns '\(racketArgumentName(family.functionName)))
      (chickadee-failed \(JSONValue.string("`\(family.functionName)` is not defined").racketLiteral)))
    """
}

// MARK: - Kind bodies

/// `.differential` — compares the student's function against the instructor's
/// reference implementation, spliced verbatim into the generated module.
///
/// The reference is called with `apply`, because the call context hands its
/// arguments over as a list — the same list `chickadee-call` takes to reach
/// into the student's namespace. The student's function still goes through
/// `chickadee-call`: it lives in a separately-loaded module, and this one does
/// not.
///
/// The instructor's source is spliced into a `#lang racket/base` module, so it
/// must be definitions only — a `#lang` line of its own would not parse there.
/// That is stated in the kind's documentation rather than validated, because
/// deciding what is "a definition" needs a Racket reader.
///
/// A failure IN THE REFERENCE is `errored`, not `failed`: a student cannot make
/// it raise except through inputs the instructor chose.
private func racketDifferentialCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let reference = family.referenceImplementation ?? ""
    return """
        \(prelude)

        \(ctx.declBlock)

        ; Instructor's reference implementation, rendered verbatim.
        \(reference)

        (define expected
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-errored (string-append \(JSONValue.string(GeneratedMessage.referenceFailed).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (apply \(family.differentialReferenceName) \(ctx.argList))))

        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (if (chickadee-equal? actual expected)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.wrongValue).racketLiteral) "\\n"
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

private func racketEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String, unordered: Bool
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let compare = unordered ? "chickadee-unordered-equal?" : "chickadee-equal?"
    // Python names "wrong value" for boundaryEquality and not for
    // unorderedEquality; the conformance matrix pins that a kind uses the same
    // vocabulary in every language, so the difference is carried here rather
    // than invented.
    let mismatchPrefix =
        unordered ? "" : JSONValue.string(GeneratedMessage.wrongValue).racketLiteral + " \"\\n\""
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (if (\(compare) actual expected)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append \(mismatchPrefix)
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

private func racketApproximateCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let tolerance = JSONValue.double(family.defaults.tolerance ?? 1e-6).racketLiteral
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        (define tolerance \(tolerance))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (unless (and (real? actual) (real? expected))
          (chickadee-failed (string-append                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                             \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        (define delta (abs (- actual expected)))
        (if (<= delta tolerance)
            (chickadee-passed (string-append "Returned " (chickadee-format actual)))
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual) "\\n"
                               \(JSONValue.string(GeneratedMessage.delta).racketLiteral) (chickadee-format delta))))
        """ + "\n"
}

/// `variableEquality` names a module-level VALUE rather than a function, so it
/// reads the binding with `chickadee-value`. Safe to evaluate bare even under
/// BSL: the operator-position restriction applies to procedures, not data.
private func racketVariableEqualityCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let target = racketArgumentName(family.functionName)
    return """
        \(prelude)

        (define expected \(racketExpected(c)))
        (define ns (chickadee-load-student))
        (unless (chickadee-defined? ns '\(target))
          (chickadee-failed \(JSONValue.string("`\(family.functionName)` is not defined").racketLiteral)))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append "the variable could not be read" "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-value ns '\(target))))

        (if (chickadee-equal? actual expected)
            (chickadee-passed (string-append "\(racketComment(family.functionName)) = " (chickadee-format actual)))
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.wrongValue).racketLiteral) "\\n"
                                                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format actual))))
        """ + "\n"
}

private func racketReturnTypeCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let expectedType: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected-type \(JSONValue.string(expectedType).racketLiteral))
        \(racketLoadAndGuard(family))

        (define actual
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList))))

        (define actual-type (chickadee-type-name actual))
        (if (string=? actual-type expected-type)
            (chickadee-passed (string-append "Returned a " actual-type))
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-type "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) actual-type)))
        """ + "\n"
}

/// Racket has no exception TYPES in the Python sense that a student would name,
/// so the expectation is matched against the message — the same posture the Lua
/// renderer takes for the same reason.
private func racketExceptionCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let expectedText: String = {
        if case .string(let s) = c.expected { return s }
        return ""
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected-error \(JSONValue.string(expectedText).racketLiteral))
        \(racketLoadAndGuard(family))

        (define outcome
          (with-handlers ([exn:fail? (lambda (e) (cons 'raised (exn-message e)))])
            (cons 'returned (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList)))))

        (cond
          [(eq? (car outcome) 'returned)
           (chickadee-failed (string-append "expected an error\\n"
                              \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                              \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-error "\\n"
                              \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format (cdr outcome))))]
          [(or (string=? expected-error "")
               (regexp-match? (regexp (regexp-quote expected-error)) (cdr outcome)))
           (chickadee-passed "Raised the expected error")]
          [else
           (chickadee-failed (string-append                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) expected-error "\\n"
                              \(JSONValue.string(GeneratedMessage.error).racketLiteral) (cdr outcome)))])
        """ + "\n"
}

private func racketPerformanceCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    let budgetMs: Double = {
        switch c.expected {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return 1000
        }
    }()
    return """
        \(prelude)

        \(ctx.declBlock)
        (define budget-ms \(budgetMs))
        \(racketLoadAndGuard(family))

        (define start (current-inexact-milliseconds))
        (with-handlers ([exn:fail? (lambda (e)
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                               \(JSONValue.string(GeneratedMessage.performanceError).racketLiteral) (exn-message e))))])
          (chickadee-call ns '\(racketArgumentName(family.functionName)) \(ctx.argList)))
        (define elapsed (- (current-inexact-milliseconds) start))

        (if (<= elapsed budget-ms)
            (chickadee-passed (format "Completed in ~ams" (round elapsed)))
            (chickadee-failed (string-append "too slow\\n"
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.threshold).racketLiteral) (format "~ams" budget-ms) "\\n"
                               \(JSONValue.string(GeneratedMessage.elapsed).racketLiteral) (format "~ams" (round elapsed)))))
        """ + "\n"
}

private func racketStdoutCase(
    family: PatternFamily, case c: PatternCase, prelude: String
) -> String {
    let ctx = racketCallContext(for: family, case: c)
    return """
        \(prelude)

        \(ctx.declBlock)
        (define expected \(racketExpected(c)))
        \(racketLoadAndGuard(family))

        (define printed
          (with-handlers ([exn:fail? (lambda (e)
              (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                                 \(JSONValue.string(GeneratedMessage.error).racketLiteral) (exn-message e))))])
            (let-values ([(out _) (chickadee-call/capture ns '\(racketArgumentName(family.functionName)) \(ctx.argList))])
              out)))

        (if (chickadee-stdout-matches? printed expected)
            (chickadee-passed "Printed the expected output")
            (chickadee-failed (string-append                                \(JSONValue.string(GeneratedMessage.input).racketLiteral) \(ctx.inputPreview) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format printed))))
        """ + "\n"
}

// MARK: - Existence guard

/// The cases `dependsOn` this, so a missing target fails once here and the cases
/// skip through the runner's dependency gate. `failed` (exit 1), never `errored`
/// (exit 2) — the gate keys on a failure, and an error would leave the dependent
/// cases running against a function that is not there.
func renderRacketExistenceGuard(family: PatternFamily, specHash: String) -> String {
    let name = family.functionName
    return """
        ; Test: \(racketComment(name)) is defined
        ; Generated from pattern family "\(racketComment(family.name))" [\(family.id)] spec_hash=\(specHash) — edit the family, not this file.
        ; Existence guard: the family's cases depend on this test, so a missing
        ; target fails once here and the cases skip instead of erroring one by one.
        #lang racket/base
        (require "test_runtime.rkt")

        (define ns (chickadee-load-student))
        (if (chickadee-defined? ns '\(racketArgumentName(name)))
            (chickadee-passed \(JSONValue.string("`\(name)` is defined").racketLiteral))
            (chickadee-failed \(JSONValue.string("`\(name)` is not defined — define it in your submission.").racketLiteral)))
        """ + "\n"
}
