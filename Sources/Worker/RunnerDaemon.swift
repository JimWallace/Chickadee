// Worker/RunnerDaemon.swift

import Foundation
import ArgumentParser
import Core

// MARK: - Entry point

@main
struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "chickadee-runner",
        abstract: "Chickadee build runner — polls the API server and processes submissions",
        version: ChickadeeVersion.current
    )

    @Option(name: .long, help: "Base URL of the API server (e.g. http://localhost:8080)")
    var apiBaseURL: String = "http://localhost:8080"

    @Option(name: .long, help: "Unique identifier for this runner instance")
    var workerID: String = "worker-\(ProcessInfo.processInfo.hostName)"

    @Option(name: .long, help: "Maximum number of concurrent jobs")
    var maxJobs: Int = 4

    @Flag(name: .long, help: "Run test scripts inside a sandbox (network-isolated, privilege-dropped)")
    var sandbox: Bool = false

    @Option(name: .long, help: "Runner shared secret for API auth (or RUNNER_SHARED_SECRET env var)")
    var workerSecret: String?

    mutating func run() async throws {
        guard let baseURL = URL(string: apiBaseURL) else {
            fputs("Error: invalid --api-base-url '\(apiBaseURL)'\n", stderr)
            throw ExitCode.failure
        }

        let cliSecret = workerSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let env = ProcessInfo.processInfo.environment
        let envSecret = (env["RUNNER_SHARED_SECRET"] ?? env["WORKER_SHARED_SECRET"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveWorkerSecret = cliSecret.isEmpty ? envSecret : cliSecret
        guard !effectiveWorkerSecret.isEmpty else {
            fputs("Error: missing runner secret. Use --worker-secret or set RUNNER_SHARED_SECRET.\n", stderr)
            throw ExitCode.failure
        }

        let poller   = JobPoller(apiBaseURL: baseURL, workerID: workerID, workerSecret: effectiveWorkerSecret)
        let reporter = Reporter(apiBaseURL: baseURL, workerID: workerID, workerSecret: effectiveWorkerSecret)
        let runner: any ScriptRunner = sandbox ? SandboxedScriptRunner() : UnsandboxedScriptRunner()

        let daemon = WorkerDaemon(
            poller:            poller,
            reporter:          reporter,
            runner:            runner,
            workerID:          workerID,
            workerSecret:      effectiveWorkerSecret,
            maxConcurrentJobs: maxJobs
        )

        let sandboxLabel = sandbox ? "sandboxed" : "unsandboxed"
        fputs("Runner \(workerID) starting — polling \(apiBaseURL) (max \(maxJobs) concurrent jobs, \(sandboxLabel))\n", stderr)
        try await daemon.run()
    }
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    private let poller:   JobPoller
    private let reporter: Reporter
    private let runner:   any ScriptRunner
    private let workerID: String
    private let workerSecret: String
    private let maxConcurrentJobs: Int

    init(
        poller:   JobPoller,
        reporter: Reporter,
        runner:   any ScriptRunner,
        workerID: String,
        workerSecret: String,
        maxConcurrentJobs: Int
    ) {
        self.poller            = poller
        self.reporter          = reporter
        self.runner            = runner
        self.workerID          = workerID
        self.workerSecret      = workerSecret
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxConcurrentJobs {
                group.addTask { try await self.workerLoop() }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Per-worker loop

    private func workerLoop() async throws {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(30))
        while true {
            if let job = try await poller.requestJob() {
                backoff.reset()
                do {
                    try await process(job)
                } catch {
                    fputs("[\(workerID)] Error processing job \(job.submissionID): \(error)\n", stderr)
                    try? await reportProcessingFailure(job: job, error: error)
                }
            } else {
                let delay = backoff.next()
                try await Task.sleep(for: delay)
            }
        }
    }

    // MARK: - Job processing

    private func process(_ job: Job) async throws {
        fputs("[\(workerID)] Processing submission \(job.submissionID)\n", stderr)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Download and unzip both zips.
        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let testSetupZip  = workDir.appendingPathComponent("testsetup.zip")
        let testSetupDir  = workDir.appendingPathComponent("testsetup", isDirectory: true)
        try FileManager.default.createDirectory(at: testSetupDir, withIntermediateDirectories: true)

        try await download(url: job.submissionURL, to: submissionZip)
        try await download(url: job.testSetupURL,  to: testSetupZip)
        try unzip(testSetupZip, to: testSetupDir)

        let manifest = job.manifest

        // Copy or unzip the submission depending on whether it is a raw file or a zip.
        if let filename = job.submissionFilename {
            let dest = testSetupDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: submissionZip, to: dest)
        } else {
            try unzip(submissionZip, to: testSetupDir)
        }

        // Optional make step.
        if let makefile = manifest.makefile {
            try runMake(in: testSetupDir, target: makefile.target)
        }

        // Run repository-managed notebook prep build step before tests.
        try runRepositoryPrepMakefile(in: testSetupDir)

        // Install shared Python test runtime helpers for every run.
        try writePythonRuntimeHelpers(in: testSetupDir)
        try writeStudentModuleHint(in: testSetupDir, submissionFilename: job.submissionFilename)

        // Install shared R test runtime helpers for every run.
        try writeRRuntimeHelper(in: testSetupDir)

        // Run each test script and collect outcomes.
        var outcomes: [TestOutcome] = []
        for entry in manifest.testSuites {
            let scriptURL = testSetupDir.appendingPathComponent(entry.script)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                fputs("[\(workerID)] Warning: script not found: \(entry.script)\n", stderr)
                continue
            }

            let output = await runner.run(
                script:           scriptURL,
                workDir:          testSetupDir,
                timeLimitSeconds: manifest.timeLimitSeconds
            )

            let isFirstAttempt = job.attemptNumber == 1
            let outcome = interpretOutput(output, entry: entry, attemptNumber: job.attemptNumber, isFirstAttempt: isFirstAttempt)
            outcomes.append(outcome)
        }

        let collection = makeCollection(outcomes: outcomes, job: job)
        try await reporter.report(collection)

        fputs("[\(workerID)] Reported result for \(job.submissionID) — \(collection.buildStatus.rawValue)\n", stderr)
    }

    // MARK: - Script output interpretation

    private func interpretOutput(
        _ output: ScriptOutput,
        entry: TestSuiteEntry,
        attemptNumber: Int,
        isFirstAttempt: Bool
    ) -> TestOutcome {
        let status: TestStatus
        if output.timedOut {
            status = .timeout
        } else {
            switch output.exitCode {
            case 0:  status = .pass
            case 1:  status = .fail
            default: status = .error
            }
        }

        // Parse the last non-empty stdout line as optional JSON for score/shortResult.
        let lastLine = output.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })

        var shortResult: String

        if let line = lastLine,
           let data = line.data(using: .utf8),
           let json = try? JSONDecoder().decode(ScriptResultJSON.self, from: data) {
            shortResult = json.shortResult ?? status.defaultShortResult
            // json.score reserved for Phase 5 gamification
        } else if let line = lastLine {
            shortResult = line
        } else {
            shortResult = status.defaultShortResult
        }

        let stderrText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let longResult: String? = {
            guard status != .pass else { return stderrText.isEmpty ? nil : stderrText }
            var sections: [String] = []
            if !stdoutText.isEmpty {
                sections.append("stdout:\n\(stdoutText)")
            }
            if !stderrText.isEmpty {
                sections.append("stderr:\n\(stderrText)")
            }
            if sections.isEmpty { return nil }
            return sections.joined(separator: "\n\n")
        }()
        let baseName = (entry.script as NSString).deletingPathExtension

        return TestOutcome(
            testName:           baseName.isEmpty ? entry.script : baseName,
            testClass:          nil,
            tier:               entry.tier,
            status:             status,
            shortResult:        shortResult,
            longResult:         longResult,
            executionTimeMs:    output.executionTimeMs,
            memoryUsageBytes:   nil,
            attemptNumber:      attemptNumber,
            isFirstPassSuccess: isFirstAttempt && status == .pass
        )
    }

    // MARK: - Collection assembly

    private func makeCollection(outcomes: [TestOutcome], job: Job) -> TestOutcomeCollection {
        let passCount    = outcomes.filter { $0.status == .pass    }.count
        let failCount    = outcomes.filter { $0.status == .fail    }.count
        let errorCount   = outcomes.filter { $0.status == .error   }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count
        let totalMs      = outcomes.reduce(0) { $0 + $1.executionTimeMs }

        let buildStatus: BuildStatus = outcomes.isEmpty ? .failed : .passed

        return TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   job.attemptNumber,
            buildStatus:     buildStatus,
            compilerOutput:  nil,
            outcomes:        outcomes,
            totalTests:      outcomes.count,
            passCount:       passCount,
            failCount:       failCount,
            errorCount:      errorCount,
            timeoutCount:    timeoutCount,
            executionTimeMs: totalMs,
            runnerVersion:   "shell-runner/1.0",
            timestamp:       Date()
        )
    }

    // MARK: - Subprocess helpers

    private func download(url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(workerSecret, forHTTPHeaderField: "X-Worker-Secret")
        request.setValue(workerID, forHTTPHeaderField: "X-Worker-Id")
        let (tmpURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkerDaemonError.downloadFailed(url)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }

    private func unzip(_ zipFile: URL, to directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments     = ["-q", "-o", zipFile.path, "-d", directory.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.unzipFailed(zipFile)
        }
    }

    private func runMake(in directory: URL, target: String?) throws {
        let proc = Process()
        proc.executableURL   = URL(fileURLWithPath: "/usr/bin/make")
        proc.arguments       = target.map { [$0] } ?? []
        proc.currentDirectoryURL = directory
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.makeFailed(target)
        }
    }

    private func runRepositoryPrepMakefile(in directory: URL) throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceMakefile = repoRoot.appendingPathComponent("Tools/runner-support/Makefile")
        guard FileManager.default.fileExists(atPath: sourceMakefile.path) else {
            return
        }

        let localMakefile = directory.appendingPathComponent("ChickadeePrep.mk")
        if FileManager.default.fileExists(atPath: localMakefile.path) {
            try FileManager.default.removeItem(at: localMakefile)
        }
        try FileManager.default.copyItem(at: sourceMakefile, to: localMakefile)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        proc.arguments = ["-f", localMakefile.lastPathComponent]
        proc.currentDirectoryURL = directory
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.prepMakeFailed
        }
    }

    private func reportProcessingFailure(job: Job, error: Error) async throws {
        let message = String(describing: error)
        let collection = TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   job.attemptNumber,
            buildStatus:     .failed,
            compilerOutput:  message,
            outcomes:        [],
            totalTests:      0,
            passCount:       0,
            failCount:       0,
            errorCount:      1,
            timeoutCount:    0,
            executionTimeMs: 0,
            runnerVersion:   "shell-runner/1.0",
            timestamp:       Date()
        )
        try await reporter.report(collection)
    }

    private func writeRRuntimeHelper(in directory: URL) throws {
        let rRuntimeURL = directory.appendingPathComponent("test_runtime.R")
        try testRuntimeR.write(to: rRuntimeURL, atomically: true, encoding: .utf8)
    }

    private func writePythonRuntimeHelpers(in directory: URL) throws {
        let runtimeURL = directory.appendingPathComponent("test_runtime.py")
        try testRuntimePy.write(to: runtimeURL, atomically: true, encoding: .utf8)

        // Python auto-imports sitecustomize (if present on sys.path), which
        // lets helpers be available without explicit imports in each test file.
        let sitecustomizeURL = directory.appendingPathComponent("sitecustomize.py")
        try sitecustomizePy.write(to: sitecustomizeURL, atomically: true, encoding: .utf8)
    }

    private func writeStudentModuleHint(in directory: URL, submissionFilename: String?) throws {
        let hintURL = directory.appendingPathComponent(".chickadee_student_module")
        if FileManager.default.fileExists(atPath: hintURL.path) {
            try FileManager.default.removeItem(at: hintURL)
        }

        guard let submissionFilename, !submissionFilename.isEmpty else { return }
        let submittedName = URL(fileURLWithPath: submissionFilename).lastPathComponent
        guard !submittedName.isEmpty else { return }

        let ext = URL(fileURLWithPath: submittedName).pathExtension.lowercased()
        let preferredModuleFile: String
        if ext == "py" {
            preferredModuleFile = submittedName
        } else if ext == "ipynb" {
            preferredModuleFile = (submittedName as NSString).deletingPathExtension + ".py"
        } else {
            return
        }
        guard !preferredModuleFile.isEmpty else { return }
        try preferredModuleFile.write(to: hintURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Script result JSON (optional last-line protocol)

/// Scripts may optionally write this as their last stdout line to report a score.
private struct ScriptResultJSON: Decodable {
    let score: Double?
    let shortResult: String?
}

private let testRuntimePy = """
import inspect
import importlib.util
import json
import sys
import traceback
from pathlib import Path
from typing import Dict, List, Optional, Any


def _caller_file(depth: int = 3) -> Path:
    frame = inspect.stack()[depth]
    return Path(frame.filename)


def _first_comment_label() -> str:
    path = _caller_file()
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#!") or s.startswith("# -*-"):
                continue
            if s.startswith("#"):
                label = s.lstrip("#").strip()
                return label if label else path.stem
            break
    except Exception:
        pass
    return path.stem


def _emit(payload: Dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def passed(message: Optional[str] = None):
    label = _first_comment_label()
    _emit({
        "shortResult": message or f"{label}: passed",
        "status": "pass",
        "test": label,
    })
    raise SystemExit(0)


def failed(message: str = "failed"):
    label = _first_comment_label()
    _emit({
        "shortResult": f"{label}: failed",
        "status": "fail",
        "test": label,
        "error": message,
    })
    raise SystemExit(1)


def errored(message: str = "error", err: Optional[Exception] = None):
    label = _first_comment_label()
    summary = message.strip() if isinstance(message, str) and message.strip() else "error"
    payload = {
        "shortResult": f"{label}: {summary}",
        "status": "error",
        "test": label,
        "error": summary,
    }
    if err is not None:
        payload["exception"] = repr(err)
        payload["traceback"] = traceback.format_exc()
    _emit(payload)
    raise SystemExit(2)


def _candidate_student_files() -> List[Path]:
    cwd = Path(".")
    files: List[Path] = []
    for p in cwd.glob("*.py"):
        name = p.name
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
            continue
        lower = name.lower()
        if lower.startswith("publictest") or lower.startswith("secrettest") or lower.startswith("releasetest"):
            continue
        files.append(p)
    return sorted(files, key=_student_file_sort_key)


def _student_file_sort_key(path: Path):
    lower = path.name.lower()
    if lower == "assignment.py":
        return (90, lower)
    if lower in {"solution.py", "submission.py"}:
        return (0, lower)
    return (10, lower)


def _preferred_student_module() -> Optional[Path]:
    hint = Path(".chickadee_student_module")
    if not hint.exists():
        return None
    try:
        raw = hint.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not raw:
        return None
    preferred = Path(raw).name
    if not preferred.endswith(".py"):
        return None
    path = Path(preferred)
    return path if path.exists() else None


def _module_name_for_path(path: Path) -> str:
    stem = path.stem
    safe = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in stem)
    if not safe:
        safe = "student"
    if safe[0].isdigit():
        safe = f"m_{safe}"
    return f"student_{safe}"


def _ordered_student_files() -> List[Path]:
    preferred = _preferred_student_module()
    # When a specific submission module is hinted, only evaluate that file.
    # This avoids accidentally resolving functions from setup-side helpers
    # like solution.py/assignment.py.
    if preferred is not None:
        return [preferred]
    return _candidate_student_files()


_loaded_student_modules: Optional[Dict[str, Any]] = None
_loaded_student_order: List[str] = []
_student_module_errors: Dict[str, str] = {}


def load_student_modules(force_reload: bool = False) -> Dict[str, Any]:
    global _loaded_student_modules, _loaded_student_order, _student_module_errors
    if _loaded_student_modules is not None and not force_reload:
        return _loaded_student_modules

    modules: Dict[str, Any] = {}
    order: List[str] = []
    errors: Dict[str, str] = {}

    for path in _ordered_student_files():
        key = path.name
        try:
            module_name = _module_name_for_path(path)
            spec = importlib.util.spec_from_file_location(module_name, path)
            if spec is None or spec.loader is None:
                errors[key] = "Could not create import spec."
                continue
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)
            modules[key] = module
            order.append(key)
        except Exception:
            errors[key] = traceback.format_exc()

    _loaded_student_modules = modules
    _loaded_student_order = order
    _student_module_errors = errors
    return modules


def student_module_errors() -> Dict[str, str]:
    return _student_module_errors


def student_module_names_in_load_order() -> List[str]:
    return list(_loaded_student_order)


def load_student_module():
    modules = load_student_modules()
    if not _loaded_student_order:
        return None
    return modules.get(_loaded_student_order[0])


def require_function(name: str):
    modules = load_student_modules()
    for key in _loaded_student_order:
        module = modules.get(key)
        if module is None:
            continue
        fn = getattr(module, name, None)
        if fn is not None and callable(fn):
            return fn

    if not modules:
        errors = student_module_errors()
        if errors:
            first_name = next(iter(errors.keys()))
            errored(
                "Could not load any student Python module from submission. "
                f"First load failure came from '{first_name}'."
            )
        errored("Could not load a student Python module from submission.")

    errored(f"Required function '{name}' was not found or is not callable in loaded student modules.")
"""

private let sitecustomizePy = """
import builtins
import test_runtime as _tr

builtins.passed = _tr.passed
builtins.failed = _tr.failed
builtins.errored = _tr.errored
builtins.require_function = _tr.require_function

_student_modules = _tr.load_student_modules()
builtins.student_modules = _student_modules
_student_module = _tr.load_student_module()
builtins.student_module = _student_module
for _module_name in _tr.student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith("_"):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
"""

// MARK: - R test runtime

// Injected into every test working directory alongside the Python helpers.
// Hand-formatted JSON output avoids any dependency on jsonlite or other packages
// that may not be present on a bare R install.
let testRuntimeR = #"""
passed <- function(message = NULL) {
    msg <- if (is.null(message)) "passed" else as.character(message)
    cat(paste0('{"shortResult":"', msg, '"}'), "\n")
    quit(status = 0)
}

failed <- function(message = "failed") {
    cat(paste0('{"shortResult":"', as.character(message), '"}'), "\n")
    quit(status = 1)
}

errored <- function(message = "error") {
    cat(paste0('{"shortResult":"', as.character(message), '"}'), "\n")
    quit(status = 2)
}
"""#

// MARK: - Helpers

private extension TestStatus {
    var defaultShortResult: String {
        switch self {
        case .pass:    return "passed"
        case .fail:    return "failed"
        case .error:   return "error"
        case .timeout: return "timed out"
        }
    }
}

// MARK: - ExponentialBackoff

struct ExponentialBackoff {
    private let initial: Duration
    private let max: Duration
    private var current: Duration

    init(initial: Duration, max: Duration) {
        self.initial = initial
        self.max     = max
        self.current = initial
    }

    mutating func next() -> Duration {
        let doubled = min(current.components.seconds * 2, max.components.seconds)
        current = Duration.seconds(doubled)
        let jittered = Double.random(in: 0...Double(doubled))
        return Duration.seconds(jittered)
    }

    mutating func reset() {
        current = initial
    }
}

// MARK: - Errors

enum WorkerDaemonError: Error, LocalizedError {
    case downloadFailed(URL)
    case unzipFailed(URL)
    case makeFailed(String?)
    case prepMakeFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):  return "Failed to download \(url)"
        case .unzipFailed(let url):     return "Failed to unzip \(url.lastPathComponent)"
        case .makeFailed(let target):   return "make \(target ?? "") failed"
        case .prepMakeFailed:           return "Repository prep Makefile failed"
        }
    }
}
