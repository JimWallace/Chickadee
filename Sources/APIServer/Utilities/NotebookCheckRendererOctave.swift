// APIServer/Utilities/NotebookCheckRendererOctave.swift
//
// The Octave half of the notebook-check renderer.
//
// WHICH KINDS OCTAVE SUPPORTS — five of ten, more than Lua's four, and each
// answered from what Octave and the vendored `chickadee-octave` env actually
// provide rather than by copying a neighbour:
//
//   * The four data-frame kinds (`dataFrameShape`, `dataFrameColumns`,
//     `dataFrameEquality`, `seriesEquality`) are REFUSED. Core Octave has no
//     data-frame type — no `table`, and the Octave Forge `dataframe` package
//     is not on emscripten-forge, so neither runner could load one. A struct
//     of columns is not a data frame, and pretending otherwise would grade
//     something the instructor did not ask about.
//   * `figureCount` IS supported — the opposite of Lua's answer, verified in
//     BOTH runners rather than assumed: the wasm kernel's plotly toolkit
//     creates figure objects headlessly, and the runner image carries
//     gnuplot-nox + fonts-freefont-otf, the two packages that make headless
//     `figure`/`plot` work under octave-cli (without them figure() errors
//     "no graphics toolkits are available!" at validation time).
//   * `cellContains` supports `regex: true` — again the opposite of Lua, and
//     again verified: Octave's `regexp` is PCRE, so `\d`, alternation and
//     `{n,m}` all behave as a Python-authoring instructor expects.
//   * `astStructure` is Python-only by design, as it is for R and Lua.
//
// Declaring the gap is the point. `NotebookCheckValidator` rejects an
// unsupported kind at SAVE time with a message naming what this language does
// support, so an instructor finds out while authoring rather than through a
// grading error — and `everyNotebookCheckKindRendersOrIsADeclaredException` in
// the conformance matrix requires each exception to be listed explicitly.

import Core
import Foundation

/// Whether `kind` has an Octave renderer. See the file comment for the
/// reasoning behind each answer.
func notebookCheckKindSupportsOctave(_ kind: NotebookCheckKind) -> Bool {
    switch kind {
    case .variableExists, .functionExists, .numericArrayClose, .cellContains, .figureCount:
        return true
    case .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality, .astStructure:
        return false
    }
}

/// Renders one notebook check as an Octave test script. Callers must have
/// already gated on `notebookCheckKindSupportsOctave`; an unsupported kind
/// renders a script that fails with an explicit message rather than trapping,
/// so a spec that slips past validation still produces a readable result.
func renderOctaveNotebookCheck(_ check: NotebookCheck, specHash: String) -> String {
    switch check.kind {
    case .variableExists: return renderOctaveVariableExists(check, specHash: specHash)
    case .functionExists: return renderOctaveFunctionExists(check, specHash: specHash)
    case .numericArrayClose: return renderOctaveNumericArrayClose(check, specHash: specHash)
    case .cellContains: return renderOctaveCellContains(check, specHash: specHash)
    case .figureCount: return renderOctaveFigureCount(check, specHash: specHash)
    case .dataFrameShape, .dataFrameColumns, .dataFrameEquality, .seriesEquality, .astStructure:
        return octaveUnsupportedCheck(check, specHash: specHash)
    }
}

// MARK: - Shared preamble

/// The provenance header plus the runtime handle every generated Octave check
/// opens with. The `% Test:` line MUST come first so the runner's label
/// extraction agrees across languages.
private func octaveCheckHeader(_ check: NotebookCheck, specHash: String, label: String) -> String {
    """
    % Test: \(octaveComment(label))
    % Generated from notebook check [\(check.id)] spec_hash=\(specHash) — edit the check, not this file.
    chickadee = test_runtime();
    """
}

/// A check whose kind has no Octave renderer. Fails with a message that names
/// the kind, rather than trapping or silently passing — a check that quietly
/// passed would award marks nobody verified.
private func octaveUnsupportedCheck(_ check: NotebookCheck, specHash: String) -> String {
    """
    \(octaveCheckHeader(check, specHash: specHash, label: "unsupported check"))

    chickadee.errored("The '\(octaveComment(check.kind.rawValue))' notebook check is not available for Octave assignments.");
    """
}

// MARK: - Kind bodies

/// `.variableExists` — the submission defines a variable, optionally of a
/// stated type.
private func renderOctaveVariableExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? ""
    let typeGuard: String = {
        guard let expected = check.expectedType, !expected.isEmpty else { return "" }
        return """


                if !(\(octaveTypeCheckExpression(typeName: expected, valueExpr: "actual")))
                    chickadee.failed(["Variable `" variable_name "` has the \(GeneratedMessage.wrongReturnType)\\n" ...
                        "\(GeneratedMessage.expected)" \(JSONValue.string(expected).octaveLiteral) "\\n" ...
                        "\(GeneratedMessage.got)" class(actual)]);
                end
            """
    }()
    return """
        \(octaveCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) is defined"))

        variable_name = \(JSONValue.string(name).octaveLiteral);

        student = chickadee.load_student();

        if !chickadee.has_var(student, variable_name)
            chickadee.failed(["Variable `" variable_name "` is not defined in your notebook."]);
        end
        actual = chickadee.get_var(student, variable_name);\(typeGuard)

        chickadee.passed(["`" variable_name "` is defined"]);
        """
}

/// `.functionExists` — the submission defines a callable of the given name,
/// optionally with a specific arity. Octave's `nargin(fn)` reports a negative
/// count for a function taking `varargin`, mirroring how the Python renderer
/// lets `*args` satisfy any expected arity at or above the required
/// positionals.
private func renderOctaveFunctionExists(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? ""
    let arityGuard: String = {
        guard let arity = check.expectedArity else { return "" }
        return """


                expected_arity = \(arity);
                try
                    declared = nargin(target);
                catch
                    declared = -1;
                end
                if declared >= 0 && declared != expected_arity
                    chickadee.failed(["`" function_name "` takes " num2str(declared) ...
                        " parameter(s)\\n" ...
                        "\(GeneratedMessage.expected)a function of exactly " num2str(expected_arity) " parameter(s)"]);
                end
                if declared < 0 && (abs(declared) - 1) > expected_arity
                    chickadee.failed(["`" function_name "` requires more parameters than expected\\n" ...
                        "\(GeneratedMessage.expected)a function callable with " num2str(expected_arity) " argument(s)"]);
                end
            """
    }()
    return """
        \(octaveCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) is defined"))

        function_name = \(JSONValue.string(name).octaveLiteral);

        student = chickadee.load_student();
        target = chickadee.require_fn(student, function_name);\(arityGuard)

        chickadee.passed(["`" function_name "` is defined"]);
        """
}

/// `.numericArrayClose` — a numeric sequence within a tolerance, element by
/// element, reporting the first element that is out.
private func renderOctaveNumericArrayClose(_ check: NotebookCheck, specHash: String) -> String {
    let name = check.variable ?? "array"
    let expected = check.expectedArray ?? []
    // numpy's `assert_allclose` defaults, the same pair the other renderers of
    // this kind use, so a check authored against any keeps its tolerance.
    let rtol = JSONValue.double(check.rtol ?? 1e-7).octaveLiteral
    let atol = JSONValue.double(check.atol ?? 0.0).octaveLiteral
    let expectedLiteral =
        "[" + expected.map { JSONValue.double($0).octaveLiteral }.joined(separator: ", ") + "]"
    return """
        \(octaveCheckHeader(check, specHash: specHash, label: check.name ?? "\(name) values"))

        variable_name = \(JSONValue.string(name).octaveLiteral);
        expected = \(expectedLiteral);
        rtol = \(rtol);
        atol = \(atol);

        student = chickadee.load_student();

        if !chickadee.has_var(student, variable_name)
            chickadee.failed(["Variable `" variable_name "` is not defined in your notebook."]);
        end
        actual = chickadee.get_var(student, variable_name);

        if !isnumeric(actual) && !islogical(actual)
            chickadee.failed(["Variable `" variable_name "` could not be read as a sequence of numbers.\\n" ...
                "\(GeneratedMessage.got)" class(actual)]);
        end
        if numel(actual) != numel(expected)
            chickadee.failed(["Variable `" variable_name "` has the wrong length.\\n" ...
                "\(GeneratedMessage.expected)" num2str(numel(expected)) " values\\n" ...
                "\(GeneratedMessage.got)" num2str(numel(actual)) " values"]);
        end

        % Mirrors numpy's allclose, including its equal_nan default: two NaNs
        % agree, and two infinities of the same sign agree. Non-finite
        % positions are settled by those two rules alone and never by the
        % tolerance — `rtol * Inf` is `Inf`, which would otherwise make every
        % infinity match every other one.
        flat_actual = double(actual(:));
        flat_expected = expected(:);
        for i = 1:numel(flat_expected)
            a = flat_actual(i);
            e = flat_expected(i);
            if isnan(a) || isnan(e)
                ok = isnan(a) && isnan(e);
            elseif isinf(a) || isinf(e)
                ok = isinf(a) && isinf(e) && (sign(a) == sign(e));
            else
                ok = abs(a - e) <= (atol + rtol * abs(e));
            end
            if !ok
                chickadee.failed(["Variable `" variable_name "` is not close enough to expected.\\n" ...
                    "\(GeneratedMessage.position)" num2str(i) "\\n" ...
                    "\(GeneratedMessage.expected)" chickadee.format(e) "\\n" ...
                    "\(GeneratedMessage.got)" chickadee.format(a)]);
            end
        end

        chickadee.passed(["`" variable_name "` matches all " num2str(numel(expected)) " expected value(s)"]);
        """
}

/// `.cellContains` — a source-level check: some cell of the notebook contains
/// the given text (or matches the given PCRE, when `regex: true`). Reads
/// `chickadee.student_cells()`, which splits on the inert cell markers
/// `extractOctave` writes.
///
/// Regex IS supported here, unlike Lua: Octave's `regexp` is backed by PCRE,
/// so a pattern authored against the Python renderer transfers — the same
/// reason R's renderer accepts it via `grepl(perl = TRUE)`. Verified with
/// `\\d`, alternation and `{n,m}` against octave-cli before claiming it.
private func renderOctaveCellContains(_ check: NotebookCheck, specHash: String) -> String {
    let needle = check.containsText ?? ""
    let label = check.name ?? notebookCheckKindHandler(for: check.kind).defaultLabel(check)
    let useRegex = check.regex == true
    let matchExpr =
        useRegex
        ? "!isempty(regexp(cell_text, needle, \"once\"))"
        : "!isempty(strfind(cell_text, needle))"

    let mustDifferBlock: String
    if let mustDiffer = check.mustDifferFrom {
        mustDifferBlock = """
            must_differ_from = \(JSONValue.string(mustDiffer).octaveLiteral);
            reference = ck_ws_normalize(must_differ_from);
            all_identical = true;
            for i = 1:numel(matched)
                if !strcmp(ck_ws_normalize(matched{i}), reference)
                    all_identical = false;
                    break;
                end
            end
            if all_identical
                chickadee.failed(["The cell containing `" needle "` is identical to the example.\\n" ...
                    "\(GeneratedMessage.expected)a cell that contains `" needle "` AND differs from the example\\n" ...
                    "\(GeneratedMessage.hint)write your own version, not a copy of the prompt's example"]);
            end
            """
    } else {
        mustDifferBlock = "% (no must-differ-from constraint)"
    }

    return """
        \(octaveCheckHeader(check, specHash: specHash, label: label))

        needle = \(JSONValue.string(needle).octaveLiteral);

        % Whitespace-normalize both sides of the must-differ comparison, so
        % trailing newlines or a re-indent don't disguise a copy of the example.
        function out = ck_ws_normalize(s)
            out = strtrim(regexprep(s, '\\s+', " "));
        end

        cells = chickadee.student_cells();
        matched = {};
        for i = 1:numel(cells)
            cell_text = cells{i};
            if \(matchExpr)
                matched{end + 1} = cell_text;
            end
        end

        if isempty(matched)
            chickadee.failed(["No code cell in your notebook matches `" needle "`.\\n" ...
                "\(GeneratedMessage.expected)at least one cell containing the pattern\\n" ...
                "\(GeneratedMessage.searched)" num2str(numel(cells)) " code cell(s)"]);
        end

        \(mustDifferBlock)

        chickadee.passed(["Found " num2str(numel(matched)) " cell(s) containing `" needle "`"]);
        """
}

/// `.figureCount` — the notebook produced at least `minFigures` figures.
///
/// The submission is loaded first (creating whatever figures its plotting
/// calls make — invisibly, since no display is attached in either runner),
/// then the root object's figure children are counted. `findall` rather than
/// `get(0, "children")` so figures with HandleVisibility off still count.
private func renderOctaveFigureCount(_ check: NotebookCheck, specHash: String) -> String {
    let minFigures = check.minFigures ?? 1
    return """
        \(octaveCheckHeader(check, specHash: specHash, label: check.name ?? "produces \(minFigures) figure(s)"))

        min_figures = \(minFigures);

        student = chickadee.load_student();
        figure_count = numel(findall(0, "type", "figure"));

        if figure_count < min_figures
            chickadee.failed(["Your notebook produced " num2str(figure_count) " figure(s).\\n" ...
                "\(GeneratedMessage.expectedAtLeast)" num2str(min_figures) " figure(s)\\n" ...
                "\(GeneratedMessage.hint)make sure your plotting cells actually run (plot, bar, hist, ...)"]);
        end

        chickadee.passed(["Produced " num2str(figure_count) " figure(s)"]);
        """
}
