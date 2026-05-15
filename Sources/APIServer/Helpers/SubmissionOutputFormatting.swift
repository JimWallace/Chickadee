// APIServer/Helpers/SubmissionOutputFormatting.swift
//
// Pure output-formatting helpers for the submission results view.
// Extracted from WebRoutes+Submission.swift (#495) — no behaviour change.
// These functions parse and format script stdout/stderr and the
// chickadee.py JSON envelope into the strings shown to students.

import Core
import Foundation
import Vapor

struct SubmitFormBody: Content {
    /// The uploaded file. Vapor's File type automatically captures the original
    /// filename from the multipart Content-Disposition header, so no separate
    /// uploadFilename field is needed.
    var files: File
}

/// Detects the dependency-skip message format and extracts the blocking test name.
/// Matches: `Skipped: prerequisite 'test_build.py' did not pass`
func parseSkip(shortResult: String) -> (isSkipped: Bool, blockerName: String?) {
    let prefix = "Skipped: prerequisite '"
    let suffix = "' did not pass"
    guard shortResult.hasPrefix(prefix), shortResult.hasSuffix(suffix) else { return (false, nil) }
    let start = shortResult.index(shortResult.startIndex, offsetBy: prefix.count)
    let end = shortResult.index(shortResult.endIndex, offsetBy: -suffix.count)
    guard start <= end else { return (false, nil) }
    let raw = String(shortResult[start..<end])
    // Strip file extension so "test_build.py" becomes "test_build"
    let name: String
    if let dot = raw.lastIndex(of: ".") {
        name = String(raw[..<dot])
    } else {
        name = raw
    }
    return (true, name.isEmpty ? nil : name)
}

func detailedScriptOutput(from raw: String?, status: TestStatus) -> String? {
    guard status != .pass else { return nil }
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let stderr = extractLabeledOutputSection("stderr", in: trimmed)
    let stdout = extractLabeledOutputSection("stdout", in: trimmed)

    if let best = bestDetailedSection(stderr: stderr, stdout: stdout) {
        return best
    }

    return trimmed
}

func formattedShortResult(from raw: String, status: TestStatus) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return defaultShortResult(for: status) }

    if let summary = extractStructuredSummaryText(from: trimmed) {
        return summary
    }
    if let summary = detailedScriptOutput(from: trimmed, status: status)
        .flatMap(extractStructuredSummaryText(from:))
    {
        return summary
    }

    return trimmed
}

func formattedDetailedOutput(primary raw: String?, fallback: String?, status: TestStatus) -> String? {
    guard status != .pass else { return nil }
    let base =
        detailedScriptOutput(from: raw, status: status)
        ?? detailedScriptOutput(from: fallback, status: status)
    guard let base else { return nil }

    if let extracted = extractStructuredErrorText(from: base) {
        return extracted
    }
    if let traceback = extractTraceback(in: base) {
        return traceback
    }
    return base
}

func formattedPassingDetailedOutput(primary raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let stdout = extractLabeledOutputSection("stdout", in: trimmed) {
        return stdout
    }
    if let stderr = extractLabeledOutputSection("stderr", in: trimmed) {
        return stderr
    }
    return trimmed
}

func extractStructuredSummaryText(from text: String) -> String? {
    guard let data = text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data)
    else {
        return nil
    }
    return structuredSummaryText(from: object)
}

private func structuredSummaryText(from value: Any) -> String? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    if let dict = value as? [String: Any] {
        let preferredKeys = ["shortResult", "error", "message", "detail", "reason", "status"]
        for key in preferredKeys {
            if let nested = dict[key],
                let text = structuredSummaryText(from: nested)
            {
                return text
            }
        }
    }

    if let array = value as? [Any] {
        for nested in array {
            if let text = structuredSummaryText(from: nested) {
                return text
            }
        }
    }

    return nil
}

private func defaultShortResult(for status: TestStatus) -> String {
    switch status {
    case .pass: return "passed"
    case .fail: return "failed"
    case .error: return "error"
    case .timeout: return "timed out"
    }
}

func extractTraceback(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let markers = [
        "Traceback (most recent call last):",
        "Traceback (most recent call last)",
        "RRuntimeError:",
        "PythonError:",
    ]

    for marker in markers {
        if let range = trimmed.range(of: marker) {
            let traceback = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !traceback.isEmpty {
                return traceback
            }
        }
    }

    return nil
}

private func bestDetailedSection(stderr: String?, stdout: String?) -> String? {
    let candidates = [stderr, stdout].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !candidates.isEmpty else { return nil }

    for candidate in candidates {
        if extractStructuredErrorText(from: candidate) != nil {
            return candidate
        }
    }
    for candidate in candidates {
        if extractTraceback(in: candidate) != nil {
            return candidate
        }
    }
    return stderr ?? stdout
}

func extractStructuredErrorText(from text: String) -> String? {
    guard let data = text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data)
    else {
        return nil
    }

    if let traceback = extractTracebackFromJSONObject(object) {
        return traceback
    }
    if let messages = extractStructuredMessages(from: object), !messages.isEmpty {
        return messages.joined(separator: "\n\n")
    }
    return nil
}

private func extractTracebackFromJSONObject(_ value: Any) -> String? {
    if let string = value as? String {
        return extractTraceback(in: string)
    }

    if let dict = value as? [String: Any] {
        let preferredKeys = [
            "traceback", "stackTrace", "stack", "stderr", "error",
            "message", "detail", "reason", "longResult",
        ]
        for key in preferredKeys {
            if let nested = dict[key],
                let traceback = extractTracebackFromJSONObject(nested)
            {
                return traceback
            }
        }
        for nested in dict.values {
            if let traceback = extractTracebackFromJSONObject(nested) {
                return traceback
            }
        }
    }

    if let array = value as? [Any] {
        for nested in array {
            if let traceback = extractTracebackFromJSONObject(nested) {
                return traceback
            }
        }
    }

    return nil
}

private func extractStructuredMessages(from value: Any) -> [String]? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : [trimmed]
    }

    if let dict = value as? [String: Any] {
        let preferredKeys = ["stderr", "error", "message", "detail", "reason", "longResult"]
        var messages: [String] = []
        for key in preferredKeys {
            guard let nested = dict[key],
                let nestedMessages = extractStructuredMessages(from: nested)
            else { continue }
            messages.append(contentsOf: nestedMessages)
        }
        if !messages.isEmpty {
            var seen: Set<String> = []
            return messages.filter { seen.insert($0).inserted }
        }
    }

    if let array = value as? [Any] {
        let messages = array.compactMap { extractStructuredMessages(from: $0) }.flatMap { $0 }
        return messages.isEmpty ? nil : messages
    }

    return nil
}

func extractLabeledOutputSection(_ label: String, in text: String) -> String? {
    let marker = "\(label):\n"
    guard let start = text.range(of: marker) else { return nil }
    let body = text[start.upperBound...]

    if let nextSection = body.range(of: #"\n\n[a-zA-Z_]+:\n"#, options: .regularExpression) {
        let section = String(body[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }
    let section = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
    return section.isEmpty ? nil : section
}

func inferredRawSubmissionExtension(data: Data, uploadFilename: String?) -> String {
    if let uploadFilename {
        let ext = URL(fileURLWithPath: uploadFilename).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty {
            return ext.lowercased()
        }
    }

    // Heuristic: notebook uploads are JSON with "nbformat" key.
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["nbformat"] != nil
    {
        return "ipynb"
    }

    return "txt"
}
