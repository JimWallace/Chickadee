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
func preferredStudentModuleFilename(
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
        case .lua: sourceExtension = "lua"
        case .octave: sourceExtension = "m"
        case .cpp: sourceExtension = "cpp"
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

/// The language the staged submission's notebook positively declares, or nil
/// when it declares nothing recognisable (or is not a notebook at all).
///
/// Detection is `AssignmentLanguage.fromNotebookMetadata` — the same call
/// `extractNotebooksToCode` makes, so routing and extraction cannot disagree
/// about what a notebook is. Resolves the named submission when it is an
/// `.ipynb`, otherwise the first `.ipynb` staged in `submissionDirectory`
/// (zip submissions). Any read/parse failure returns nil, so the caller keeps
/// its existing (Python) behaviour.
///
/// Generalised from `submissionIsRNotebook`, whose Bool could only mean "R, or
/// not R" — so an xeus-lua notebook answered "not R" and was routed to Python.
func submissionNotebookLanguage(
    submissionDirectory: URL, submissionFilename: String?
) -> AssignmentLanguage? {
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
        return nil
    }

    return AssignmentLanguage.fromNotebookMetadata(meta)
}

/// How a submission is prepared before the shell scripts run.
///
/// This replaced a `Bool` named `shouldNormalizePythonSubmission`, and the
/// rename is the point. A boolean can only say "Python, or the other thing",
/// so the caller had to re-derive *which* other thing with a second test —
/// `forcedLanguage: targetsR ? .r : nil`, which type-checks forever and hands
/// every language after R to the notebook sniff. Carrying the language in the
/// answer removes that second decision entirely.
enum SubmissionNormalization: Equatable, Sendable {
    /// The Python normalizer: an `.ipynb` becomes an importable module, magics
    /// are stripped, cells are wrapped for resilient load.
    case pythonModule
    /// Merge the upload and extract notebooks to source. `forcedLanguage` wins
    /// over the submission's own kernelspec, which the in-browser editor can
    /// silently rewrite; nil means "trust the notebook's metadata".
    case extractToSource(forcedLanguage: AssignmentLanguage?)
}

/// The language the MANIFEST makes the owner of this submission, or nil when
/// the manifest carries no such claim.
///
/// A language owns the submission when its own graded scripts are present and
/// Python's are not, anywhere. The Python exclusion is not symmetry — it is the
/// existing precedence, preserved deliberately: a mixed suite that ships any
/// `.py` keeps Python's normalizer, because those Python tests need an
/// importable module and nothing else in the routing would give them one.
///
/// Generalised from `manifestTargetsRSubmission`, which asked the same question
/// about R alone. Iterating `allCases` is what makes a new language an owner
/// the day its case exists, rather than silently falling through to Python.
func manifestOwningLanguage(_ manifest: TestProperties) -> AssignmentLanguage? {
    // The RECORDED language is the strongest ownership signal, and for C++ it
    // is the only one: a C++ suite's generated scripts are `.sh` wrappers, so
    // there is no extension to sniff — exactly the "suite made up only of
    // pattern families" blindness the recorded field exists to fix. Python is
    // the default and never claims by record (nil-recorded manifests keep the
    // sniffing behaviour below unchanged).
    if let recorded = manifest.language, recorded != .default { return recorded }
    func suiteContains(_ language: AssignmentLanguage) -> Bool {
        manifest.testSuites.contains {
            AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
                == language
        }
    }
    let hasRequiredPython = manifest.requiredFiles.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0).pathExtension) == .python
    }
    guard !suiteContains(.python), !hasRequiredPython else { return nil }
    return AssignmentLanguage.allCases
        .filter { $0 != .default }
        .first(where: suiteContains)
}

/// Which normalization this submission needs.
///
/// The bucket-C inversion (docs/language-handling-review.md §4) applied to the
/// one site that had resisted it. It used to read "R, or else Python", with
/// Python reached by falling through extension and content probes rather than
/// by being named — so a third language was normalized as Python with no
/// compiler error, and a Lua notebook submission was turned into a Python
/// module that the Lua suite could not grade.
///
/// Stated positively, the order below is: Python's explicit claims first, then
/// another language's ownership, then the submission's own declaration, then
/// Python's heuristics, then give up and extract generically. Steps 1, 4, 5 and
/// 6 are Python answering "is this mine?"; steps 2 and 3 are another language
/// answering the same question. Nothing asks "is it R?" any more.
func submissionNormalization(
    manifest: TestProperties,
    submissionFilename: String?,
    submissionDirectory: URL
) -> SubmissionNormalization {
    // 1. A required `.py` is an explicit demand for an importable module.
    let requiredPythonFiles = manifest.requiredFiles.filter {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0).pathExtension) == .python
    }
    if !requiredPythonFiles.isEmpty { return .pythonModule }

    // 2. Another language owns the manifest: extract to ITS source, whatever
    //    the submission's kernelspec says. The manifest is authoritative about
    //    the assignment's language; the submission metadata is not, because the
    //    in-browser editor can rewrite it.
    if let owner = manifestOwningLanguage(manifest) {
        return .extractToSource(forcedLanguage: owner)
    }

    let hasPythonSuite = manifest.testSuites.contains {
        AssignmentLanguage(scriptExtension: URL(fileURLWithPath: $0.script).pathExtension)
            == .python
    }

    // 3. No Python suite, and the submission itself positively declares a
    //    non-default language: honour that rather than treating any `.ipynb` as
    //    Python at step 4. Generalised from the old `submissionIsRNotebook`.
    if !hasPythonSuite,
        let declared = submissionNotebookLanguage(
            submissionDirectory: submissionDirectory, submissionFilename: submissionFilename),
        declared != .default
    {
        return .extractToSource(forcedLanguage: declared)
    }

    // 4-6. Python's heuristics: it is the default, so it claims the shapes that
    //      no other language has claimed by now.
    if let submissionFilename {
        let ext = URL(fileURLWithPath: submissionFilename).pathExtension.lowercased()
        if pythonSubmissionExtensions.contains(ext) { return .pythonModule }
    }
    if hasPythonSuite { return .pythonModule }
    if let enumerator = FileManager.default.enumerator(
        at: submissionDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if pythonSubmissionExtensions.contains(fileURL.pathExtension.lowercased()) {
                return .pythonModule
            }
        }
    }

    // 7. Nothing claimed it. Extract generically and trust the notebook.
    return .extractToSource(forcedLanguage: nil)
}

/// Upload shapes Python claims when nothing else has. `json` is here because a
/// notebook saved without its extension still parses as one.
private let pythonSubmissionExtensions: Set<String> = ["py", "ipynb", "json"]

/// Retained as a thin wrapper over `submissionNormalization` so existing
/// callers and tests keep working; the routing itself no longer asks a boolean
/// question of a three-language system.
func shouldNormalizePythonSubmission(
    manifest: TestProperties,
    submissionFilename: String?,
    submissionDirectory: URL
) -> Bool {
    submissionNormalization(
        manifest: manifest,
        submissionFilename: submissionFilename,
        submissionDirectory: submissionDirectory
    ) == .pythonModule
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
