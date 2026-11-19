// APIServer/Utilities/RunnerVersionReport.swift
//

/// One runner's ID and the version it last advertised. The runner-version-skew
/// alert reads a list of these so that its message can name the runner that is
/// behind: an unnamed "1 runner(s) behind" paged every 30 minutes for four days
/// in Nov 2026 without saying that the runner was `Sparrow`.
struct RunnerVersionReport: Sendable, Equatable {
    let runnerID: String
    let version: String
}
