// APIServer/Utilities/AuthoringChecks/ExpressionErrorCheck.swift
//
// Reports per-student expressions that fail to evaluate for a validation-variant
// seed (#2747). Seeds that fail with the same error are one finding, so an
// expression that fails for every seed reads as one problem.

import Core

struct ExpressionErrorCheck: AuthoringCheck {
    static let id = "personalization.expressionError"
    static let severity = AuthoringFinding.Severity.error

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        var seedsByError: [(error: String, seeds: [String])] = []
        for evaluation in snapshot.seedEvaluations {
            guard let error = evaluation.error else { continue }
            if let index = seedsByError.firstIndex(where: { $0.error == error }) {
                seedsByError[index].seeds.append(evaluation.seedHex)
            } else {
                seedsByError.append((error, [evaluation.seedHex]))
            }
        }
        let total = snapshot.seedEvaluations.count
        return seedsByError.map { group in
            finding(
                at: .assignment,
                "The per-student expressions fail for \(group.seeds.count) of \(total) validation seeds: "
                    + group.error,
                fix: "Call preview_personalization with seedHex \(group.seeds[0]) to reproduce it.")
        }
    }
}
