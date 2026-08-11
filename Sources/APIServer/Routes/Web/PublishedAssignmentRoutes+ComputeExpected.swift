// APIServer/Routes/Web/PublishedAssignmentRoutes+ComputeExpected.swift
//
//   POST /instructor/:assignmentID/compute-expected
//
// Computes a pattern-family case's expected value by calling the reference
// solution — in the assignment's OWN language.
//
// WHY THIS IS A SERVER ENDPOINT AND NOT A SECOND BROWSER RUNTIME.
// The editor already had auto-compute: `/python-eval-worker.js`, a Python kernel
// in a Web Worker. It worked, and it only ever worked for Python — on an R,
// Lua, Octave, C++ or Racket assignment it did not fail, it computed a PYTHON
// answer for a value that would be compared against that language's result.
// Wrong and confident is worse than absent.
//
// The obvious fix is a kernel per language in the browser. That is the wrong
// one: `PersonalizationEvaluator` on this server ALREADY evaluates expressions
// in all six, behind an exhaustive switch, with a timeout, spawning the real
// interpreter — it is what resolves every per-student `=` expression. The
// browser worker was a parallel implementation of something already solved six
// ways. Routing here deletes the parallel one rather than growing it fivefold,
// and a seventh language inherits auto-compute the day its driver arm exists.
//
// The costs, stated: a round trip instead of an in-page call, and one
// subprocess per request. The evaluator's own timeout bounds the second, and
// the editor already debounces auto-compute. Nothing new crosses a trust
// boundary — instructor validation runs solutions on this server already.
//
// WHAT IT CANNOT DO, and says so rather than guessing. The drivers report values
// as their language's REPR — there is no JSON in base R or Lua to serialize with
// — so a scalar round-trips into the Expected cell and a composite may not. The
// response carries the raw rendering and the CLIENT decides whether it parses,
// using the language-aware reader it already has for hand-typed values. Deciding
// here would mean a second parser per language on the server, which is the
// duplication this whole endpoint exists to remove.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    struct ComputeExpectedRequest: Content {
        /// The solution function to call.
        var functionName: String
        /// Positional arguments, as the JSON the editor already stores.
        var args: [JSONValue]
        /// Compare printed output rather than the return value.
        var captureStdout: Bool?
    }

    struct ComputeExpectedResponse: Content {
        var ok: Bool
        /// The value rendered as a literal in the assignment's language — what
        /// an instructor would have typed.
        var rendered: String?
        var error: String?
        /// Set when the assignment's language cannot be evaluated at all.
        var unsupportedReason: String?
    }

    @Sendable
    func computeExpectedValue(req: Request) async throws -> Response {
        // Authoring action, so the same TA+ gate the script and suite editors
        // use — this executes the instructor's reference solution.
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let input = try req.content.decode(ComputeExpectedRequest.self)
        guard let manifest = setup.decodedManifest() else {
            throw WebAssignmentError.invalidParameter(
                name: "assignmentID", reason: "Manifest is not valid JSON")
        }

        guard let language = AssignmentLanguage.resolve(for: setup, manifest: manifest) else {
            return try await ComputeExpectedResponse(
                ok: false, rendered: nil, error: nil,
                unsupportedReason:
                    "This assignment declares no language, so there is no solution to call."
            ).encodeResponse(for: req)
        }
        guard PersonalizationEvaluator.supportsEvaluation(language) else {
            return try await ComputeExpectedResponse(
                ok: false, rendered: nil, error: nil,
                unsupportedReason:
                    "Computing an expected value is not available for \(language.displayName) assignments."
            ).encodeResponse(for: req)
        }

        // The call, written in the assignment's language: the function name as
        // the author gave it, and each argument rendered by the SAME
        // `literal(_:)` the generated test will use — so what is computed here
        // and what runs at grade time are the same expression.
        let renderedArgs = input.args.map { language.literal($0) }
        guard
            let call = solutionCallExpression(
                functionName: input.functionName, arguments: renderedArgs, language: language,
                captureStdout: input.captureStdout == true)
        else {
            return try await ComputeExpectedResponse(
                ok: false, rendered: nil, error: nil,
                unsupportedReason:
                    "Computing printed output automatically is not available for "
                    + "\(language.displayName) assignments — type the expected output instead."
            ).encodeResponse(for: req)
        }

        let expression = PersonalizationExpression(name: "ck_expected", expression: call)
        let supportDir = req.application.testSetupsDirectory + "shared/\(assignment.testSetupID)/"
        do {
            let values = try await PersonalizationEvaluator.evaluate(
                // A fixed seed: this is the instructor's own preview of the
                // reference answer, not a per-student value. A personalized
                // family is previewed through `preview_personalization`, which
                // resolves a real student's seed.
                seedHex: String(repeating: "0", count: 16),
                staticVariables: [],
                expressions: [expression],
                supportFilesDirectory: supportDir,
                language: language
            )
            guard let rendered = values["ck_expected"] else {
                return try await ComputeExpectedResponse(
                    ok: false, rendered: nil,
                    error: "The solution produced no value.", unsupportedReason: nil
                ).encodeResponse(for: req)
            }
            return try await ComputeExpectedResponse(
                ok: true, rendered: rendered, error: nil, unsupportedReason: nil
            ).encodeResponse(for: req)
        } catch {
            // The instructor sees the driver's own message: a missing function,
            // a wrong arity, an exception in their solution. Those are the
            // things they can act on, and the previous worker surfaced them too.
            return try await ComputeExpectedResponse(
                ok: false, rendered: nil,
                error: String(describing: error), unsupportedReason: nil
            ).encodeResponse(for: req)
        }
    }

    /// The expression that calls the reference solution, or nil when this
    /// language has no single-expression spelling for what was asked.
    ///
    /// Per-language because the CALL is per-language: the solution is loaded
    /// under a module name in Python and as bare definitions everywhere else,
    /// and capturing printed output has no shared spelling at all. Exhaustive,
    /// so a seventh language answers here too.
    ///
    /// STDOUT CAPTURE IS THE HONEST GAP. R's `capture.output` and Octave's
    /// `evalc` express it in one expression; Lua, Racket and C++ need statements
    /// the evaluator's single-expression contract has no room for, and Python's
    /// spelling is a `redirect_stdout` context manager that does not survive
    /// being flattened into one. Those return nil and the instructor is told the
    /// value has to be typed — which is strictly better than the previous
    /// behaviour, where a stdout_equality case on an R assignment was auto-filled
    /// with what PYTHON printed.
    private func solutionCallExpression(
        functionName: String, arguments: [String], language: AssignmentLanguage,
        captureStdout: Bool
    ) -> String? {
        let args = arguments.joined(separator: ", ")
        switch language {
        case .python:
            return captureStdout ? nil : "solution.\(functionName)(\(args))"
        case .r:
            let call = "\(functionName)(\(args))"
            return captureStdout
                ? "paste(capture.output(print(\(call))), collapse = \"\\n\")" : call
        case .octave:
            let call = "\(functionName)(\(args))"
            return captureStdout ? "evalc(\"disp(\(call))\")" : call
        case .lua:
            return captureStdout ? nil : "\(functionName)(\(args))"
        case .racket:
            return captureStdout
                ? nil : "(\(functionName) \(arguments.joined(separator: " ")))"
        case .cpp:
            return captureStdout ? nil : "\(functionName)(\(args))"
        case .java:
            // `functionName` is already the qualified `Class.method` a Java
            // family carries, so it interpolates as written. No stdout capture:
            // Java's spelling is a `System.setOut` swap around the call, which
            // is three statements and does not fit the evaluator's
            // single-expression contract — the same answer Python, Lua, Racket
            // and C++ give, for the same reason.
            return captureStdout ? nil : "\(functionName)(\(args))"
        }
    }
}
