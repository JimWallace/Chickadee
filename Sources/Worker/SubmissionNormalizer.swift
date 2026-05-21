import Core
import Foundation

enum DetectedSubmissionKind {
    case pythonScript
    // Carries the raw bytes + already-parsed notebook JSON so the handler
    // doesn't re-read or re-parse the same file.
    case jupyterNotebook(data: Data, notebook: [String: Any])
    case unsupported(String)
}

struct NormalizationResult {
    let warnings: [String]
    let producedPythonFiles: [URL]
    let preferredStudentModule: String?
}

enum SubmissionNormalizationError: LocalizedError {
    case mimeDetectionFailed(String)
    case invalidPythonSubmission(String)
    case invalidNotebookJSON(String)
    case notebookHasNoCodeCells(String)
    case noPythonSourcesFound

    var errorDescription: String? {
        switch self {
        case .mimeDetectionFailed(let filename):
            return "Could not detect content type for \(filename)."
        case .invalidPythonSubmission(let filename):
            return "Uploaded file \(filename) is not a valid Python script or Jupyter notebook."
        case .invalidNotebookJSON:
            return "Notebook file appears to be invalid JSON."
        case .notebookHasNoCodeCells:
            return "Notebook file contained no code cells to grade."
        case .noPythonSourcesFound:
            return "No Python source files were found after submission normalisation."
        }
    }
}

/// Mutable accumulator threaded through the per-file normalisation phases.
/// Keeps the parent function focused on flow control while helpers update
/// the three running lists / hints they each contribute to.
private struct NormalizationProgress {
    var warnings: [String] = []
    var producedPythonFiles: [URL] = []
    var preferredStudentModule: String?
    var unsupportedOnlyFilename: String?
}

struct SubmissionNormalizer {
    private let mimeTypeDetector = MimeTypeDetector()
    private let notebookExtractor = NotebookExtractor()

    func normalizePythonSubmission(
        manifest: TestProperties,
        submissionDirectory: URL,
        workspaceDirectory: URL,
        submissionFilename: String?
    ) throws -> NormalizationResult {
        let submissionFiles = regularFiles(in: submissionDirectory)
        var progress = NormalizationProgress()

        writeStructuredRunnerLog(
            event: "submission_normalization_start",
            fields: [
                "submission_directory": submissionDirectory.path,
                "workspace_directory": workspaceDirectory.path,
                "submission_filename": submissionFilename ?? "",
                "file_count": submissionFiles.count,
            ])

        for fileURL in submissionFiles {
            try processSubmissionFile(
                fileURL: fileURL,
                submissionDirectory: submissionDirectory,
                workspaceDirectory: workspaceDirectory,
                progress: &progress
            )
        }

        try ensureProducedPythonFiles(
            progress: progress,
            submissionFiles: submissionFiles,
            workspaceDirectory: workspaceDirectory
        )

        try applyCompatibilityCopyIfNeeded(
            manifest: manifest,
            workspaceDirectory: workspaceDirectory,
            progress: &progress
        )

        writeStructuredRunnerLog(
            event: "submission_normalization_completed",
            fields: [
                "workspace_directory": workspaceDirectory.path,
                "produced_python_files": progress.producedPythonFiles.map {
                    relativePath(of: $0, under: workspaceDirectory)
                },
                "warning_count": progress.warnings.count,
            ])

        return NormalizationResult(
            warnings: progress.warnings,
            producedPythonFiles: progress.producedPythonFiles,
            preferredStudentModule: progress.preferredStudentModule
        )
    }

    private func processSubmissionFile(
        fileURL: URL,
        submissionDirectory: URL,
        workspaceDirectory: URL,
        progress: inout NormalizationProgress
    ) throws {
        let fileRelativePath = relativePath(of: fileURL, under: submissionDirectory)
        let mimeType = try mimeTypeDetector.detectMimeType(for: fileURL)
        writeStructuredRunnerLog(
            event: "submission_file_mime_detected",
            fields: [
                "file": fileRelativePath,
                "mime_type": mimeType,
            ])

        let classification = try classify(fileURL: fileURL, mimeType: mimeType)
        switch classification {
        case .pythonScript:
            try handlePythonScript(
                fileURL: fileURL,
                fileRelativePath: fileRelativePath,
                workspaceDirectory: workspaceDirectory,
                progress: &progress
            )
        case .jupyterNotebook(let data, let notebook):
            try handleJupyterNotebook(
                fileURL: fileURL,
                fileRelativePath: fileRelativePath,
                workspaceDirectory: workspaceDirectory,
                data: data,
                notebook: notebook,
                progress: &progress
            )
        case .unsupported(let reason):
            handleUnsupported(
                fileURL: fileURL,
                fileRelativePath: fileRelativePath,
                reason: reason,
                progress: &progress
            )
        }
    }

    private func handlePythonScript(
        fileURL: URL,
        fileRelativePath: String,
        workspaceDirectory: URL,
        progress: inout NormalizationProgress
    ) throws {
        let destinationURL = workspaceDirectory.appendingPathComponent(fileRelativePath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        progress.producedPythonFiles.append(destinationURL)
        progress.preferredStudentModule =
            progress.preferredStudentModule ?? preferredModuleIfRootLevel(fileRelativePath)
        writeStructuredRunnerLog(
            event: "submission_file_classified",
            fields: [
                "file": fileRelativePath,
                "classification": "python_script",
                "generated_file": fileRelativePath,
            ])
    }

    private func handleJupyterNotebook(
        fileURL: URL,
        fileRelativePath: String,
        workspaceDirectory: URL,
        data: Data,
        notebook: [String: Any],
        progress: inout NormalizationProgress
    ) throws {
        let extracted = try notebookExtractor.extractPythonSource(
            from: notebook,
            filename: fileURL.lastPathComponent
        )
        let outputRelativePath = normalizedNotebookOutputRelativePath(relativePath: fileRelativePath)
        let destinationURL = uniqueDestination(
            preferred: workspaceDirectory.appendingPathComponent(outputRelativePath)
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try extracted.source.write(to: destinationURL, atomically: true, encoding: .utf8)
        progress.producedPythonFiles.append(destinationURL)
        progress.preferredStudentModule =
            progress.preferredStudentModule
            ?? preferredModuleIfRootLevel(
                relativePath(of: destinationURL, under: workspaceDirectory)
            )

        // v0.4.114: also preserve the original notebook bytes
        // alongside the flattened .py so source-level checks
        // (`.cellContains`, future `.markdownPresent`) can read
        // the cell-by-cell structure that flattening discards.
        // Stable filename so generated tests can `Path("_submission.ipynb")`
        // without knowing the original upload name.
        let preservedNotebookURL = workspaceDirectory.appendingPathComponent("_submission.ipynb")
        if !FileManager.default.fileExists(atPath: preservedNotebookURL.path) {
            try data.write(to: preservedNotebookURL, options: .atomic)
        }

        appendNotebookExtensionWarningIfNeeded(fileURL: fileURL, progress: &progress)

        writeStructuredRunnerLog(
            event: "submission_file_classified",
            fields: [
                "file": fileRelativePath,
                "classification": "jupyter_notebook",
                "generated_file": relativePath(of: destinationURL, under: workspaceDirectory),
                "code_cell_count": extracted.codeCellCount,
            ])
    }

    private func appendNotebookExtensionWarningIfNeeded(
        fileURL: URL,
        progress: inout NormalizationProgress
    ) {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "py" {
            progress.warnings.append(
                "File \(fileURL.lastPathComponent) appears to be a Jupyter notebook. It was treated as a notebook and code cells were extracted before grading."
            )
        } else if ext != "ipynb" {
            progress.warnings.append(
                "File \(fileURL.lastPathComponent) appears to be a Jupyter notebook even though its extension is .\(ext.isEmpty ? "unknown" : ext). Code cells were extracted before grading."
            )
        }
    }

    private func handleUnsupported(
        fileURL: URL,
        fileRelativePath: String,
        reason: String,
        progress: inout NormalizationProgress
    ) {
        if progress.unsupportedOnlyFilename == nil {
            progress.unsupportedOnlyFilename = fileURL.lastPathComponent
        }
        progress.warnings.append("Ignoring unsupported file \(fileURL.lastPathComponent): \(reason)")
        writeStructuredRunnerLog(
            event: "submission_file_classified",
            fields: [
                "file": fileRelativePath,
                "classification": "unsupported",
                "reason": reason,
            ])
    }

    private func ensureProducedPythonFiles(
        progress: NormalizationProgress,
        submissionFiles: [URL],
        workspaceDirectory: URL
    ) throws {
        guard progress.producedPythonFiles.isEmpty else { return }
        if submissionFiles.count == 1, let unsupportedOnlyFilename = progress.unsupportedOnlyFilename {
            throw SubmissionNormalizationError.invalidPythonSubmission(unsupportedOnlyFilename)
        }
        writeStructuredRunnerLog(
            event: "submission_normalization_failed",
            fields: [
                "workspace_directory": workspaceDirectory.path,
                "error": SubmissionNormalizationError.noPythonSourcesFound.localizedDescription,
            ])
        throw SubmissionNormalizationError.noPythonSourcesFound
    }

    private func applyCompatibilityCopyIfNeeded(
        manifest: TestProperties,
        workspaceDirectory: URL,
        progress: inout NormalizationProgress
    ) throws {
        guard let expectedFilename = singleExpectedPythonFilename(from: manifest),
            !workspaceContains(relativePath: expectedFilename, in: workspaceDirectory),
            progress.producedPythonFiles.count == 1,
            let sourceURL = progress.producedPythonFiles.first
        else { return }

        let compatibilityURL = workspaceDirectory.appendingPathComponent(expectedFilename)
        try FileManager.default.createDirectory(
            at: compatibilityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: compatibilityURL)
        try FileManager.default.copyItem(at: sourceURL, to: compatibilityURL)
        progress.producedPythonFiles.append(compatibilityURL)
        if progress.preferredStudentModule == nil {
            progress.preferredStudentModule = preferredModuleIfRootLevel(expectedFilename)
        }
        progress.warnings.append(
            "Expected file \(expectedFilename) was not present. Chickadee created a compatibility copy from the single detected Python source file."
        )
        writeStructuredRunnerLog(
            event: "submission_compatibility_copy_created",
            fields: [
                "expected_file": expectedFilename,
                "source_file": relativePath(of: sourceURL, under: workspaceDirectory),
            ])
    }

    private func classify(fileURL: URL, mimeType: String) throws -> DetectedSubmissionKind {
        if fileURL.pathExtension.lowercased() == "ipynb" {
            let data = try Data(contentsOf: fileURL)
            let notebook = try notebookExtractor.notebookJSONObject(from: data, filename: fileURL.lastPathComponent)
            guard notebookExtractor.isNotebookJSONObject(notebook) else {
                throw SubmissionNormalizationError.invalidPythonSubmission(fileURL.lastPathComponent)
            }
            return .jupyterNotebook(data: data, notebook: notebook)
        }

        if mimeType == "application/json" {
            let data = try Data(contentsOf: fileURL)
            let notebook = try notebookExtractor.notebookJSONObject(from: data, filename: fileURL.lastPathComponent)
            return notebookExtractor.isNotebookJSONObject(notebook)
                ? .jupyterNotebook(data: data, notebook: notebook)
                : .unsupported("content is JSON but not a Jupyter notebook")
        }

        if mimeType.hasPrefix("text/") || mimeType == "application/x-empty" {
            return .pythonScript
        }

        return .unsupported("content type \(mimeType) is not supported for Python grading")
    }

    private func regularFiles(in directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files.sorted { relativePath(of: $0, under: directory) < relativePath(of: $1, under: directory) }
    }

    private func normalizedNotebookOutputRelativePath(relativePath: String) -> String {
        let relativeNSString = relativePath as NSString
        let ext = relativeNSString.pathExtension.lowercased()
        if ext == "ipynb" {
            return relativeNSString.deletingPathExtension + ".py"
        }
        let stem =
            relativeNSString.deletingPathExtension.split(separator: "/").last.map(String.init)
            ?? relativeNSString.deletingPathExtension
        let parent = relativeNSString.deletingLastPathComponent
        let generatedName = stem + ".extracted.py"
        if parent.isEmpty || parent == "." {
            return generatedName
        }
        return (parent as NSString).appendingPathComponent(generatedName)
    }

    private func uniqueDestination(preferred: URL) -> URL {
        if !FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }

        let directory = preferred.deletingLastPathComponent()
        let stem = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var index = 1
        while true {
            let candidate = directory.appendingPathComponent("\(stem).\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func singleExpectedPythonFilename(from manifest: TestProperties) -> String? {
        let pythonFiles = manifest.requiredFiles.filter {
            ($0 as NSString).pathExtension.lowercased() == "py"
        }
        return pythonFiles.count == 1 ? pythonFiles[0] : nil
    }

    private func workspaceContains(relativePath: String, in workspace: URL) -> Bool {
        FileManager.default.fileExists(atPath: workspace.appendingPathComponent(relativePath).path)
    }

    private func preferredModuleIfRootLevel(_ relativePath: String) -> String? {
        relativePath.contains("/") ? nil : (relativePath as NSString).lastPathComponent
    }
}

private func relativePath(of fileURL: URL, under rootURL: URL) -> String {
    let resolvedFilePath = fileURL.resolvingSymlinksInPath().path
    let resolvedRootPath = rootURL.resolvingSymlinksInPath().path

    if resolvedFilePath.hasPrefix(resolvedRootPath + "/") {
        return String(resolvedFilePath.dropFirst(resolvedRootPath.count + 1))
    }

    if fileURL.path.hasPrefix(rootURL.path + "/") {
        return String(fileURL.path.dropFirst(rootURL.path.count + 1))
    }

    return fileURL.lastPathComponent
}
