// Shared interpretation of a script's raw output (exit code + stdout/stderr)
// into a status + display strings. Lives in RunnerCore (embedded-safe, no
// Foundation) so the native worker and the browser runner share one
// implementation. Pinned by Tests/Fixtures/output-contract.json.

/// Status + display strings derived from a single script's raw output.
public struct InterpretedScriptResult: Equatable, Sendable {
    public let status: TestStatus
    public let shortResult: String
    public let longResult: String?

    public init(status: TestStatus, shortResult: String, longResult: String?) {
        self.status = status
        self.shortResult = shortResult
        self.longResult = longResult
    }
}

extension TestStatus {
    public var defaultShortResult: String {
        switch self {
        case .pass: return "passed"
        case .fail: return "failed"
        case .error: return "error"
        case .timeout: return "timed out"
        }
    }
}

/// Pure interpretation of a script's `ScriptOutput` into status + display
/// strings. Exit code → status (0=pass, 1/3=fail, else error; timeout wins).
/// The optional last-line JSON footer supplies `shortResult` and is stripped
/// from the student-facing `longResult`.
public func interpretScriptOutput(_ output: ScriptOutput) -> InterpretedScriptResult {
    let status: TestStatus
    if output.timedOut {
        status = .timeout
    } else {
        switch output.exitCode {
        case 0: status = .pass
        case 1: status = .fail
        case 3: status = .fail  // chickadee.py (Marmoset) uses exit 3 for "failed"
        default: status = .error
        }
    }

    let lines = splitOnNewlines(output.stdout)
    let lastLine = lines.map(trimHorizontal).last { !$0.isEmpty }

    // The footer is the last non-empty line iff it's a JSON object.
    let footer: [String: JSONValue]? = {
        guard let line = lastLine, case .object(let dict) = parseJSON(line) else { return nil }
        return dict
    }()

    let shortResult: String
    if let footer {
        if case .string(let s)? = footer["shortResult"] {
            // Drop the redundant "<test label>: " prefix — the test name is
            // already shown as the row heading, so repeating it in the one-line
            // summary is noise. (Shared by both runners; the browser runner used
            // to do this in JS.)
            shortResult = stripTestLabelPrefix(s, footer: footer)
        } else {
            shortResult = status.defaultShortResult
        }
        // a numeric "score" field is reserved for future partial credit
    } else if let lastLine {
        shortResult = lastLine
    } else {
        shortResult = status.defaultShortResult
    }

    // Strip the JSON footer line from stdout before showing it to students.
    let strippedStdout: String
    if footer != nil {
        var stdoutLines = splitOnNewlines(output.stdout)
        if let lastIdx = stdoutLines.indices.last(where: { !trimHorizontal(stdoutLines[$0]).isEmpty }) {
            stdoutLines.remove(at: lastIdx)
        }
        strippedStdout = stdoutLines.joined(separator: "\n")
    } else {
        strippedStdout = output.stdout
    }

    let stdoutText = trimWhitespaceAndNewlines(strippedStdout)
    let stderrText = trimWhitespaceAndNewlines(output.stderr)
    let longResult: String? = {
        // A footer `traceback` (emitted by test_runtime's errored(err=…)) is the
        // most useful failure detail — surface it verbatim rather than the bare
        // summary. (Shared by both runners; the browser runner used to do this.)
        if let footer, case .string(let traceback)? = footer["traceback"] {
            let trimmed = trimWhitespaceAndNewlines(traceback)
            if !trimmed.isEmpty { return trimmed }
        }
        var sections: [String] = []
        if !stdoutText.isEmpty { sections.append("stdout:\n\(stdoutText)") }
        if !stderrText.isEmpty { sections.append("stderr:\n\(stderrText)") }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }()

    return InterpretedScriptResult(status: status, shortResult: shortResult, longResult: longResult)
}

/// Strip a leading `"<test>: "` label from a footer's `shortResult` when the
/// footer carries a matching `test` field, so the one-line summary doesn't
/// repeat the test name shown as the row heading. Returns the input unchanged
/// when there's no `test` field or no matching prefix.
private func stripTestLabelPrefix(_ shortResult: String, footer: [String: JSONValue]) -> String {
    guard case .string(let label)? = footer["test"], !label.isEmpty else { return shortResult }
    let prefix = "\(label): "
    guard shortResult.hasPrefix(prefix) else { return shortResult }
    return String(shortResult.dropFirst(prefix.count))
}

// MARK: - Embedded-safe string helpers (file-private to avoid collisions)

private func splitOnNewlines(_ s: String) -> [String] {
    s.split(separator: "\n" as Character, omittingEmptySubsequences: false).map(String.init)
}

private func trimHorizontal(_ s: String) -> String {
    let isHWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
    return String(s.drop(while: isHWS).reversed().drop(while: isHWS).reversed())
}

private func trimWhitespaceAndNewlines(_ s: String) -> String {
    let isWS: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    return String(s.drop(while: isWS).reversed().drop(while: isWS).reversed())
}
