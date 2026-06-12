// Worker/RunnerStructuredLog.swift
//
// Structured (JSON-lines-on-stderr) runner logging plus `JobStageTimings`,
// the per-job stage stopwatch whose fields feed both the structured logs
// and the server's `job_execution_metrics` rows.  Split from
// RunnerDaemon.swift (June 2026 audit).

import Core
import Foundation

struct JobStageTimings {
    private var values: [String: Int] = [:]
    var testSetupCacheHit: Bool?

    mutating func measureSync<T>(_ stage: String, operation: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try operation()
        values[stage] = millisecondsSince(start)
        return result
    }

    /// Async-closure variant of `measureSync`, used by stages that need
    /// to call `await`-able helpers (e.g. `extractZipArchive` from Core).
    mutating func measure<T>(_ stage: String, operation: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await operation()
        values[stage] = millisecondsSince(start)
        return result
    }

    mutating func record(_ stage: String, milliseconds: Int) {
        values[stage] = milliseconds
    }

    func fields() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            result["\(key)_ms"] = value
        }
        if let testSetupCacheHit {
            result["test_setup_cache_hit"] = testSetupCacheHit
        }
        return result
    }

    func value(for stage: String) -> Int? {
        values[stage]
    }

    func asWorkerExecutionStageTimings() -> WorkerExecutionStageTimings {
        WorkerExecutionStageTimings(
            workdirSetupMs: value(for: "workdir_setup"),
            submissionDirSetupMs: value(for: "submission_dir_setup"),
            submissionDownloadMs: value(for: "submission_download"),
            testSetupAcquireMs: value(for: "test_setup_acquire"),
            submissionUnpackMs: value(for: "submission_unpack"),
            starterCleanupMs: value(for: "starter_cleanup"),
            submissionPrepareMs: value(for: "submission_prepare"),
            makeStepMs: value(for: "make_step"),
            runtimeHelperSetupMs: value(for: "runtime_helper_setup"),
            testExecutionMs: value(for: "test_execution"),
            testSetupCacheHit: testSetupCacheHit
        )
    }

    private func millisecondsSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// Was `private` when this lived in RunnerDaemon.swift; internal now so
// WorkerCommand.swift (same module) can keep using it after the split.
func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

func writeStructuredRunnerLog(event: String, fields: [String: Any]) {
    var payload = fields
    payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
    payload["event"] = event
    guard JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
        writeToStandardError(
            "{\"event\":\"\(event)\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n")
        return
    }
    FileHandle.standardError.write(data)
    FileHandle.standardError.write(Data("\n".utf8))
}
