// Worker/SubmissionStaging.swift
//
// Free helper functions used while staging a job's workspace — disk-space
// precheck, workspace sizing, directory merge, student-module naming,
// Python-normalization detection, and the test-setup cache key — plus
// `WorkerDaemonError`.  Split from RunnerDaemon.swift (June 2026 audit).

import Core
import Foundation

/// Returns the free space (megabytes) reported by the filesystem holding
/// `path`. Returns nil only if the OS refuses to answer; callers should
/// treat that as "skip the precheck and let downstream errors surface".
func freeSpaceMB(at path: URL) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
        let free = attrs[.systemFreeSize] as? NSNumber
    else {
        return nil
    }
    return Int(truncating: free) / (1024 * 1024)
}

/// Walks `directory` (skipping hidden files) and sums the size of every
/// regular file. Returns nil if the directory doesn't exist or can't be
/// enumerated — useful so telemetry can distinguish "0 bytes" (empty
/// workspace) from "couldn't measure" (cleanup already ran, etc.). Used
/// as a proxy for a job's peak workspace footprint — accurate enough for
/// the monotonically-growing workDir we care about.
func directorySizeBytes(at directory: URL) -> Int? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return nil
    }
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return nil
    }
    var total: Int = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else { continue }
        total += size
    }
    return total
}

func mergeDirectoryContents(from sourceDirectory: URL, into destinationDirectory: URL) throws {
    // Resolve symlinks once on the source root so that the prefix comparison
    // below works even when callers pass paths through `/var` vs `/private/var`
    // (macOS) or otherwise-aliased mounts.
    let sourceRoot = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
    let sourceRootComponents = sourceRoot.pathComponents

    guard
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return
    }

    for case let sourceURL as URL in enumerator {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }

        let resolved = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let entryComponents = resolved.pathComponents
        guard entryComponents.count > sourceRootComponents.count,
            Array(entryComponents.prefix(sourceRootComponents.count)) == sourceRootComponents
        else {
            // Enumerator handed us something outside the source root — skip
            // rather than write to an unintended destination.
            continue
        }
        let relativeComponents = Array(entryComponents.dropFirst(sourceRootComponents.count))

        var destinationURL = destinationDirectory
        for component in relativeComponents {
            destinationURL.appendPathComponent(component)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

/// Filename the extracted submission will have in the grading workspace, written
/// to `.chickadee_student_module` so the runtimes can prefer it over guessing.
///
/// `language` matters because a notebook is extracted to its assignment's source
/// language: an R job's `analysis.ipynb` becomes `analysis.R`, not `analysis.py`.
/// Naming the Python file on an R job produced a hint pointing at a file that
/// never exists, so `chickadee_student_file()` had nothing to prefer and fell
/// back to scanning. Defaults to `.python`, so the Python path is unchanged.
func legacyPreferredStudentModuleFilename(
    submissionFilename: String?,
    language: AssignmentLanguage = .python
) -> String? {
    guard let submissionFilename, !submissionFilename.isEmpty else { return nil }
    let submittedName = URL(fileURLWithPath: submissionFilename).lastPathComponent
    guard !submittedName.isEmpty else { return nil }

    let ext = URL(fileURLWithPath: submittedName).pathExtension.lowercased()
    // A source file is already the module; the extension the student used wins
    // over the assignment's language (an `.R` upload is an R module either way).
    if AssignmentLanguage(scriptExtension: ext) != nil {
        return submittedName
    }
    if ext == "ipynb" {
        let sourceExtension: String
        switch language {
        case .python: sourceExtension = "py"
        case .r: sourceExtension = "R"
        }
        return (submittedName as NSString).deletingPathExtension + "." + sourceExtension
    }
    return nil
}

func stagedSubmissionDestination(
    submissionDirectory: URL,
    submittedFilename: String
) -> URL {
    let basename = URL(fileURLWithPath: submittedFilename).lastPathComponent
    let safeName = basename.isEmpty ? "submission.bin" : basename
    return submissionDirectory.appendingPathComponent(safeName)
}

/// True when the staged submission is an **R-kernel** notebook (IRkernel `ir`,
/// legacy `webr`, or xeus-r `xr`), which must be extracted to `.R` by
/// `extractNotebooksToCode` rather than run through the Python normalizer.
///
/// Detection is `AssignmentLanguage.isRNotebookMetadata` — the same call
/// `extractNotebooksToCode` makes, so routing and extraction cannot disagree
/// about what an R notebook is. Resolves the named submission when it is an
/// `.ipynb`, otherwise the first `.ipynb` staged in `submissionDirectory`
/// (zip submissions). Any read/parse failure returns false so the caller keeps
/// its existing (Python) behaviour.
func submissionIsRNotebook(submissionDirectory: URL, submissionFilename: String?) -> Bool {
    let notebookURL: URL? = {
        if let submissionFilename,
            URL(fileURLWithPath: submissionFilename).pathExtension.lowercased() == "ipynb"
        {
            return stagedSubmissionDestination(
                submissionDirectory: submissionDirectory, submittedFilename: submissionFilename)
        }
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: submissionDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension.lowercased() == "ipynb" }
    }()

    guard let notebookURL,
        let data = try? Data(contentsOf: notebookURL),
        let notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let meta = notebook["metadata"] as? [String: Any]
    else {
        return false
    }

    return AssignmentLanguage.isRNotebookMetadata(meta)
}

/// True when the manifest's graded suite is **pure R** — at least one `.R` test
/// script and no Python (`.py` test script or required `.py` file). For such an
/// assignment every notebook submission must be extracted to `.R`, because the
/// tests `source()` a `.R` file and a `.py` extraction can never grade. The
/// manifest is authoritative about the assignment's language, so it — not the
/// submission notebook's (mangleable) kernelspec — decides. This is what lets a
/// submission whose R kernelspec was rewritten by the in-browser editor (saved
/// under the Pyodide/Python kernel) still grade as R, including a submission
/// stored before the submit-time kernel fix when it is re-tested.
func manifestTargetsRSubmission(_ manifest: TestProperties) -> Bool {
    let hasRSuite = manifest.testSuites.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension) == .r
    }
    guard hasRSuite else { return false }
    let hasPythonSuite = manifest.testSuites.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
            == .python
    }
    let hasRequiredPython = manifest.requiredFiles.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0).pathExtension) == .python
    }
    return !hasPythonSuite && !hasRequiredPython
}

func shouldNormalizePythonSubmission(
    manifest: TestProperties,
    submissionFilename: String?,
    submissionDirectory: URL
) -> Bool {
    let requiredPythonFiles = manifest.requiredFiles.filter {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0).pathExtension) == .python
    }
    if !requiredPythonFiles.isEmpty { return true }

    // A pure-R suite grades by `source()`-ing a `.R` file, so ANY notebook
    // submission must go to the generic extractor (which, forced by the same
    // predicate at the call site, emits `.R`) — regardless of the submission
    // notebook's kernelspec, which an in-browser editor can silently rewrite.
    // The manifest is authoritative about the assignment's language, so it
    // decides here rather than the possibly-mangled submission metadata.
    if manifestTargetsRSubmission(manifest) {
        return false
    }

    let hasPythonSuite = manifest.testSuites.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
            == .python
    }

    // A mixed suite that also ships R: an R-kernel notebook is still not a
    // Python submission, so route it to the generic notebook extractor
    // (`extractNotebooksToCode`, which emits `.R`) instead of the Python
    // normalizer. This must run before the extension/content probes below,
    // which would otherwise treat any `.ipynb` as Python.
    if !hasPythonSuite,
        submissionIsRNotebook(
            submissionDirectory: submissionDirectory, submissionFilename: submissionFilename)
    {
        return false
    }

    if let submissionFilename {
        let ext = URL(fileURLWithPath: submissionFilename).pathExtension.lowercased()
        if ["py", "ipynb", "json"].contains(ext) {
            return true
        }
    }

    if hasPythonSuite {
        return true
    }

    guard
        let enumerator = FileManager.default.enumerator(
            at: submissionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return false
    }
    for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let ext = fileURL.pathExtension.lowercased()
        if ["py", "ipynb", "json"].contains(ext) {
            return true
        }
    }
    return false
}

func testSetupCacheKey(for job: Job) -> String {
    let manifestBytes = (try? ManifestCodec.encoder.encode(job.manifest)) ?? Data()
    var material = Data()
    material.append(Data(job.testSetupID.utf8))
    material.append(0)
    material.append(Data(job.testSetupURL.absoluteString.utf8))
    material.append(0)
    material.append(manifestBytes)
    let digest = sha256HexDigest(material)
    return "\(job.testSetupID)-\(digest.prefix(16))"
}

// The optional last-line JSON result footer is now parsed by RunnerCore
// (interpretScriptOutput + JSONLite), and `TestStatus.defaultShortResult`
// lives there too — shared with the browser runner.

// MARK: - Errors

enum WorkerDaemonError: Error, LocalizedError {
    case downloadFailed(URL)
    case httpDownloadFailure(statusCode: Int, body: String)
    case makeFailed(target: String?, detail: String?)
    case makeTimedOut(target: String?, limitSeconds: Int)
    case insufficientDiskSpace(path: String, freeMB: Int, requiredMB: Int)
    case unsafePersonalizedFilename(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "Failed to download \(url)"
        case .httpDownloadFailure(let statusCode, let body):
            return "HTTP \(statusCode) while downloading artifacts: \(body)"
        case .makeFailed(let target, let detail):
            let heading = "make \(target ?? "") failed"
            guard let detail, !detail.isEmpty else { return heading }
            return "\(heading)\n\(detail)"
        case .makeTimedOut(let target, let limitSeconds):
            return "make \(target ?? "") exceeded the \(limitSeconds)s build time limit and was killed"
        case .insufficientDiskSpace(let path, let freeMB, let requiredMB):
            return
                "Runner workspace at \(path) has \(freeMB) MB free; need at least \(requiredMB) MB before accepting a job"
        case .unsafePersonalizedFilename(let name):
            return "Personalized file name '\(name)' is not a bare filename; refusing to write it"
        }
    }
}
