// APIServer/Utilities/AuthoringChecks/VariantFailureCheck.swift
//
// Reports each validation variant on which the reference solution failed
// (#2747). A variant grades the solution against a derived per-student seed
// (`ValidationVariant`), so a failure means a student holding such a seed gets
// material that the solution does not handle, even when the instructor's own
// validation passed.

import Core

struct VariantFailureCheck: AuthoringCheck {
    static let id = "validation.variantFailed"
    static let severity = AuthoringFinding.Severity.error

    func findings(in snapshot: AuthoringSnapshot) -> [AuthoringFinding] {
        snapshot.variants.filter { $0.status == ValidationVariant.Status.failed }.map { variant in
            let failing = (variant.run?.outcomes ?? []).filter { $0.status != .pass }.map(\.testName)
            let which =
                failing.isEmpty
                ? "Its outcomes could not be read."
                : "Failing: \(failing.joined(separator: ", "))."
            return finding(
                at: .assignment,
                "The reference solution fails validation variant \(variant.variantIndex), "
                    + "a per-student seed that a student can hold. \(which)",
                fix: "Call get_validation_result for the failing outcomes, and preview_personalization "
                    + "with seedHex \(variant.seedHex) for the values that variant received.")
        }
    }
}
