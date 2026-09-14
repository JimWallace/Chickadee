// APIServer/Helpers/FailureDetailMasking.swift
//
// Applies a suite entry's `FailureDetail` to a failing outcome at
// results-display time. The generated script printed everything it knew;
// this decides how much of that the STUDENT is shown. Staff always see the
// full text — the masking is a viewer policy, not a storage change, so a
// setting can be relaxed after the fact and every past result re-reads.
//
// Fails closed. `.actualOnly` keeps a line only when its label is in
// `GeneratedMessage.studentSideLabels`, and a first line only when it is one
// of `GeneratedMessage.failureHeadlines`; anything else is withheld. A
// hand-written script therefore degrades to the verdict under `.actualOnly`,
// because nothing about its output says which half is the answer.

import Core
import Foundation

/// The masked `shortResult` / `longResult` pair for one failing outcome.
struct MaskedFailureOutput: Equatable {
    let shortResult: String
    let longResult: String?
}

/// Applies `detail` to a failing outcome's two texts. `.full` returns them
/// unchanged. Never called for a passing outcome — a pass reveals nothing.
func maskFailureOutput(
    shortResult: String, longResult: String?, status: TestStatus, detail: FailureDetail
) -> MaskedFailureOutput {
    switch detail {
    case .full:
        return MaskedFailureOutput(shortResult: shortResult, longResult: longResult)
    case .verdictOnly:
        return MaskedFailureOutput(shortResult: verdictText(status), longResult: nil)
    case .actualOnly:
        let masked = studentSideLines(of: fullFailureText(shortResult: shortResult, longResult: longResult))
        return MaskedFailureOutput(
            shortResult: masked.headline ?? verdictText(status),
            longResult: masked.body.isEmpty ? nil : masked.body.joined(separator: "\n"))
    }
}

/// "did not pass" / "error" / "timed out" — the verdict alone.
func verdictText(_ status: TestStatus) -> String {
    switch status {
    case .pass: return "passed"
    case .fail: return "did not pass"
    case .error: return "error"
    case .timeout: return "timed out"
    }
}

/// The failure message as one text. Some runtimes (R, Lua, Octave, C++, Java)
/// carry the whole multi-line message in the footer's `shortResult`; Python
/// prints it to stdout so it lands in `longResult` under a `stdout:` section.
/// Read both, `longResult` first (it is the fuller copy when both exist),
/// with the section labels RunnerCore adds stripped.
private func fullFailureText(shortResult: String, longResult: String?) -> [String] {
    var lines: [String] = []
    if let longResult {
        for raw in longResult.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "stdout:" || trimmed == "stderr:" { continue }
            lines.append(raw)
        }
    }
    if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        lines = shortResult.components(separatedBy: "\n")
    }
    return lines
}

/// Walks the message keeping the student's side. A labelled line switches
/// keeping on or off by its label; an unlabelled line follows the label
/// before it (so a multi-line `got:` value survives whole); text before any
/// label — a traceback, a hand-written script's free prose — is dropped.
private func studentSideLines(of lines: [String]) -> (headline: String?, body: [String]) {
    guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
        return (nil, [])
    }
    let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
    // Test-runtime footers prefix the headline with the test label ("Case 3:
    // wrong value"); accept the headline anywhere after a colon too.
    let headlineText =
        firstTrimmed.split(separator: ":", maxSplits: 1)
        .last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? firstTrimmed
    let isHeadline =
        GeneratedMessage.failureHeadlines.contains(firstTrimmed)
        || GeneratedMessage.failureHeadlines.contains(headlineText)
    let headline = isHeadline ? firstTrimmed : nil

    var body: [String] = []
    var keeping = false
    var started = false
    for line in lines {
        if !started {
            started = true
            if isHeadline { continue }
        }
        if let label = fieldLabel(of: line) {
            keeping = GeneratedMessage.studentSideLabels.contains(label)
        }
        if keeping { body.append(line) }
    }
    return (headline, body)
}

/// The label of a `  name:   value` line, or nil for an unlabelled line.
/// Labels are one lowercase word, optionally followed by a parenthetical
/// (`expected (subset):`), and always end with a colon.
private func fieldLabel(of line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.firstIndex(of: ":") else { return nil }
    let head = trimmed[..<colon]
    guard !head.isEmpty, head.count <= 24,
        head.allSatisfy({ $0.isLetter || $0 == " " || $0 == "(" || $0 == ")" })
    else { return nil }
    return String(head.split(separator: " ").first ?? head)
}
