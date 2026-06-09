// APIServer/Models/SubmissionMaterialization.swift
//
// Cached, per-validation-submission personalization, resolved ONCE at enqueue
// (`materializeValidationGrading`) so the two worker-facing routes stay pure
// I/O and never run `python3`:
//
//   * `inputs` — the resolved `=` expression values (Python literals). Read by
//     `WorkerJobRoutes.buildJobPayload` and handed to the runner as
//     `Job.personalizedInputs` (→ `_ck_inputs.py`), instead of re-evaluating on
//     the poll path.
//   * The substituted solution notebook is written alongside as a
//     `<zipPath>.grading` sidecar and streamed verbatim by
//     `WorkerArtifactRoutes.downloadSubmission` — no manifest decode, no seed
//     lookup, no subprocess. This is what fixes the runner's 5 s download
//     timeout (the `#869` regression that ran the evaluator in the download
//     handler).
//
// `seedHex` pins the one seed every cached value was resolved against, so the
// answer-key notebook, `_ck_inputs.py`, and `CHICKADEE_ASSIGNMENT_SEED` all
// agree. The stored `zipPath` keeps the `{{...}}` template, so `get_solution`,
// the editor, and re-validation by another user are unaffected.

import Foundation

struct SubmissionMaterialization: Codable, Sendable {
    /// `sha256(seedHex | manifest)` — a staleness guard. Per-submission
    /// materialization can't normally go stale (a manifest edit enqueues a
    /// fresh validation submission), so this is belt-and-suspenders for edge
    /// cases (a seed reset, or a manifest mutation that didn't re-enqueue).
    let key: String
    /// The seed every cached value was resolved against; nil for a
    /// literal-only assignment that declares no per-student expressions.
    let seedHex: String?
    /// Resolved `=` expression values (Python literals), keyed by name — the
    /// same map `PersonalizationSubstitution.gradingInputs` produces. Empty for
    /// a literal-only assignment.
    let inputs: [String: String]
}

extension APISubmission {
    /// Decodes the cached personalization materialization, or nil when the
    /// submission was never materialized (student submissions, non-personalized
    /// assignments, or rows written before this fix).
    func decodedMaterialization() -> SubmissionMaterialization? {
        guard let json = materializationJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SubmissionMaterialization.self, from: data)
    }
}
