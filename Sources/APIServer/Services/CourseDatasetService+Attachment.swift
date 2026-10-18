// APIServer/Services/CourseDatasetService+Attachment.swift
//
// Attaching a course library dataset to an assignment
// (docs/datasets-course-library.md, slice 3, D2).
//
// An attachment copies the pinned version's bytes into the setup zip as an
// ordinary support file and records the source on the file's `DatasetSpec`.
// Every delivery path keeps reading the zip, so nothing downstream changes.
//
// One invariant holds the design together: a spec with a source names a
// version whose bytes are the file in the zip. Attach, update and promote
// keep it. The doors that bring a whole manifest from outside check it
// (`sourceIssue`, `reconciledLibraryFields`). The doors that write or delete
// one support file refuse an attached file (`TestProperties.libraryAttachment`).
//
// Each operation writes the zip first, then the manifest, then refreshes the
// shared support directory that the editor and personalization read. The
// re-grade, the re-validation, the version capture and the close stay with
// the caller, as for every other edit.

import Core
import Fluent
import Foundation

extension CourseDatasetService {

    /// What a new attachment asks for.
    struct AttachRequest: Sendable {
        /// The version to pin. Nil means the newest.
        var version: Int?
        /// The filename in the setup zip. Nil means the version's filename.
        var filename: String?
        /// Rows per student. Nil means the whole file.
        var sampleSize: Int?
        /// A column to balance the sample across.
        var stratumColumn: String?
        var scope: DatasetSliceScope
    }

    // MARK: - Attach

    /// Copies a version of `dataset` into `setup` and returns the spec that
    /// now names it.
    @discardableResult
    static func attach(
        _ dataset: APICourseDataset, to setup: APITestSetup, request: AttachRequest, testSetupsDirectory: String,
        on db: any Database
    ) async throws -> DatasetSpec {
        let (dataset, version) = try await liveVersion(of: dataset, number: request.version, on: db)
        guard dataset.courseID == setup.courseID else { throw CourseDatasetError.wrongCourse }
        guard let manifest = setup.decodedManifest() else { throw CourseDatasetError.unreadableManifest }

        let filename = try validatedFilename(request.filename ?? version.filename)
        try requireSupportFileName(filename, manifest: manifest)
        if manifest.libraryAttachment(for: filename) != nil { throw CourseDatasetError.alreadyAttached(filename) }
        if await listZipEntries(zipPath: setup.zipPath).contains(filename) {
            throw CourseDatasetError.fileTaken(filename)
        }

        let bytes = try bytes(of: version, blobs: AssignmentVersionBlobStore(testSetupsDirectory: testSetupsDirectory))
        let column = request.stratumColumn?.trimmingCharacters(in: .whitespaces)
        let stratum = (column?.isEmpty ?? true) ? nil : column
        let spec = DatasetSpec(
            file: filename, kind: stratum == nil ? .rowSample : .stratifiedSample, sampleSize: request.sampleSize,
            stratumColumn: stratum, source: DatasetSource(slug: dataset.slug, version: version.version),
            scope: request.scope)
        try requireValid(spec, bytes: bytes)

        try await writeThenRecord(
            PinnedWrite(filename: filename, bytes: bytes, previous: nil, dataset: dataset, version: version.version),
            setup: setup, on: db
        ) { props in
            props.datasets.removeAll { $0.file == filename }
            props.datasets.append(spec)
        }
        await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: testSetupsDirectory)
        return spec
    }

    // MARK: - Detach

    /// Ends the attachment of `filename`.
    ///
    /// With `removeFile` false the file stays as an ordinary support file and
    /// keeps its sample, so every student keeps receiving a slice rather than
    /// the pool (`DatasetSpec.withoutLibraryFields`). A course-scoped sample
    /// goes back to the assignment seed. With `removeFile` true the file and
    /// its spec go, unless a test depends on the file.
    static func detach(
        file filename: String, from setup: APITestSetup, removeFile: Bool, testSetupsDirectory: String,
        on db: any Database
    ) async throws {
        guard let manifest = setup.decodedManifest() else { throw CourseDatasetError.unreadableManifest }
        guard let attached = manifest.libraryAttachment(for: filename) else {
            throw CourseDatasetError.notAttached(filename)
        }
        if removeFile {
            let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
            guard dependents.isEmpty else { throw CourseDatasetError.fileInUse(filename, by: dependents) }
            try await mutateSetupZip(zipPath: setup.zipPath, writes: [:], deletions: [filename])
        }
        let kept = removeFile ? nil : attached.withoutLibraryFields()
        try await mutateManifest(setup: setup, on: db) { props in
            if removeFile {
                // The file is gone, so every mark that named it goes too.
                _ = clearFileMarks(filename, in: &props)
                return
            }
            guard let index = props.datasets.firstIndex(where: { $0.file == filename }) else { return }
            if let kept {
                props.datasets[index] = kept
            } else {
                props.datasets.remove(at: index)
            }
        }
        await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: testSetupsDirectory)
    }

    // MARK: - Update to another version

    /// Re-copies an attached file from another version of its dataset and
    /// returns the new spec. The sample, the stratum and the transforms carry
    /// over, and are checked again against the new bytes.
    @discardableResult
    static func updateAttachment(
        file filename: String, in setup: APITestSetup, to number: Int?, testSetupsDirectory: String,
        on db: any Database
    ) async throws -> DatasetSpec {
        guard let manifest = setup.decodedManifest() else { throw CourseDatasetError.unreadableManifest }
        guard let attached = manifest.libraryAttachment(for: filename), let source = attached.source else {
            throw CourseDatasetError.notAttached(filename)
        }
        guard let stored = try await find(courseID: setup.courseID, slug: source.slug, on: db) else {
            throw CourseDatasetError.datasetGone
        }
        let (dataset, version) = try await liveVersion(of: stored, number: number, on: db)
        guard version.version != source.version else { throw CourseDatasetError.alreadyAtVersion(version.version) }

        let bytes = try bytes(of: version, blobs: AssignmentVersionBlobStore(testSetupsDirectory: testSetupsDirectory))
        let spec = DatasetSpec(
            file: filename, kind: attached.kind, sampleSize: attached.sampleSize,
            stratumColumn: attached.stratumColumn, transforms: attached.transforms,
            source: DatasetSource(slug: dataset.slug, version: version.version), scope: attached.scope)
        try requireValid(spec, bytes: bytes)

        guard let previous = await extractZipEntry(zipPath: setup.zipPath, entryName: filename) else {
            throw CourseDatasetError.unreadableFile(filename)
        }
        try await writeThenRecord(
            PinnedWrite(
                filename: filename, bytes: bytes, previous: previous, dataset: dataset, version: version.version),
            setup: setup, on: db
        ) { props in
            guard let index = props.datasets.firstIndex(where: { $0.file == filename }) else { return }
            props.datasets[index] = spec
        }
        await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: testSetupsDirectory)
        return spec
    }

    /// True when the dataset has a newer version than the one `spec` pins.
    static func attachmentIsBehind(_ spec: DatasetSpec, dataset: APICourseDataset) -> Bool {
        guard let source = spec.source, source.slug == dataset.slug else { return false }
        return source.version < dataset.currentVersion
    }

    // MARK: - Scope

    /// Sets whether the attached file `filename` gives a student the same rows
    /// in every assignment (`.course`) or rows of this assignment's own
    /// (`.assignment`). The bytes and the sample do not change.
    @discardableResult
    static func setAttachmentScope(
        file filename: String, in setup: APITestSetup, to scope: DatasetSliceScope, on db: any Database
    ) async throws -> DatasetSpec {
        guard let manifest = setup.decodedManifest() else { throw CourseDatasetError.unreadableManifest }
        guard let attached = manifest.libraryAttachment(for: filename) else {
            throw CourseDatasetError.notAttached(filename)
        }
        if let issue = DatasetSpecValidation.scopeIssue(with: attached.withScope(scope)) {
            throw CourseDatasetError.attachmentIssue(issue)
        }
        // The new spec is made from the manifest being written, not from the
        // one read above: a lost race re-applies this closure to a newer
        // manifest, whose spec may name another version or another sample.
        // A spec that is no longer attached is left alone.
        try await mutateManifest(setup: setup, on: db) { props in
            guard let index = props.datasets.firstIndex(where: { $0.file == filename }),
                props.datasets[index].source != nil
            else { return }
            props.datasets[index] = props.datasets[index].withScope(scope)
        }
        return attached.withScope(scope)
    }

    // MARK: - Promote

    /// Creates a library dataset whose version 1 is the support file
    /// `filename` of `setup`, and attaches the file to it. The bytes do not
    /// change, and a sample the file already has is kept, so every student
    /// keeps the rows they had.
    static func promote(
        file filename: String, from setup: APITestSetup, dataset input: NewDataset, testSetupsDirectory: String,
        on db: any Database
    ) async throws -> (dataset: APICourseDataset, spec: DatasetSpec) {
        guard let manifest = setup.decodedManifest() else { throw CourseDatasetError.unreadableManifest }
        try requireSupportFileName(filename, manifest: manifest)
        if manifest.libraryAttachment(for: filename) != nil { throw CourseDatasetError.alreadyAttached(filename) }
        guard let bytes = await extractZipEntry(zipPath: setup.zipPath, entryName: filename) else {
            throw CourseDatasetError.unreadableFile(filename)
        }

        let (dataset, version) = try await create(
            courseID: setup.courseID, dataset: input,
            upload: Upload(filename: filename, bytes: bytes, note: "Moved from an assignment"),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: testSetupsDirectory), on: db)
        let source = DatasetSource(slug: dataset.slug, version: version.version)
        let existing = manifest.datasetSpecsByFile[filename]
        let spec = DatasetSpec(
            file: filename, kind: existing?.kind ?? .rowSample, sampleSize: existing?.sampleSize,
            stratumColumn: existing?.stratumColumn, transforms: existing?.transforms ?? [], source: source,
            scope: .assignment)
        try await mutateManifest(setup: setup, on: db) { props in
            props.datasets.removeAll { $0.file == filename }
            props.datasets.append(spec)
        }
        await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: testSetupsDirectory)
        return (dataset, spec)
    }

    // MARK: - Doors that bring a whole manifest

    /// Why `spec`'s library fields cannot be stored in a setup of `courseID`
    /// whose zip is at `zipPath`, or nil. A source must name a dataset and a
    /// version in the course, and the file must be that version's bytes.
    static func sourceIssue(
        for spec: DatasetSpec, courseID: UUID, zipPath: String, on db: any Database
    ) async throws -> String? {
        if let issue = DatasetSpecValidation.scopeIssue(with: spec) { return issue }
        guard let source = spec.source else { return nil }
        guard let dataset = try await find(courseID: courseID, slug: source.slug, on: db) else {
            return "'\(spec.file)' names the library dataset '\(source.slug)', which this course does not have."
        }
        guard let version = try await version(source.version, of: dataset, on: db) else {
            return "'\(spec.file)' names version \(source.version) of '\(source.slug)', which does not exist."
        }
        guard let bytes = await extractZipEntry(zipPath: zipPath, entryName: spec.file),
            sha256HexDigest(bytes) == version.sha256
        else {
            return "'\(spec.file)' is not the same file as version \(source.version) of '\(source.slug)'."
        }
        return nil
    }

    /// `props` with every library source that fails `sourceIssue` removed, and
    /// the files whose source was removed. For the doors that copy a whole
    /// manifest into a course or rebuild a zip (clone, bundle import, version
    /// restore, the draft suite-file upload and the draft publish): the file
    /// and its sample stay, so no student starts to receive the pool, and the
    /// spec stops claiming a library version the course does not have. A
    /// course scope goes with the source, so a course-scoped sample is dealt
    /// again with the assignment seed.
    static func reconciledLibraryFields(
        _ props: TestProperties, courseID: UUID, zipPath: String, on db: any Database
    ) async throws -> (props: TestProperties, dropped: [String]) {
        var reconciled = props
        var dropped: [String] = []
        var specs: [DatasetSpec] = []
        for spec in props.datasets {
            guard spec.source != nil || spec.scope != .assignment,
                try await sourceIssue(for: spec, courseID: courseID, zipPath: zipPath, on: db) != nil
            else {
                specs.append(spec)
                continue
            }
            dropped.append(spec.file)
            if let kept = spec.withoutLibraryFields() { specs.append(kept) }
        }
        reconciled.datasets = specs
        return (reconciled, dropped)
    }

    // MARK: - Rules

    /// The dataset as stored now and its version `number` (the newest when
    /// nil), read fresh so an operation never acts on a deleted dataset.
    private static func liveVersion(
        of dataset: APICourseDataset, number: Int?, on db: any Database
    ) async throws -> (APICourseDataset, APICourseDatasetVersion) {
        guard let fresh = try await APICourseDataset.find(dataset.requireID(), on: db) else {
            throw CourseDatasetError.datasetGone
        }
        let wanted = number ?? fresh.currentVersion
        guard let version = try await version(wanted, of: fresh, on: db) else {
            throw CourseDatasetError.unknownVersion(wanted)
        }
        return (fresh, version)
    }

    /// A library file must be a support data file: not a test, not a canonical
    /// notebook, and not grader-only.
    private static func requireSupportFileName(_ filename: String, manifest: TestProperties) throws {
        let scripts = Set(manifest.testSuites.map(\.script))
        guard !scripts.contains(filename), !reservedSetupEntryNames.contains(filename),
            !manifest.graderOnlyFileSet.contains(filename)
        else { throw CourseDatasetError.notASupportFile(filename) }
    }

    /// Writes `bytes` into the zip, re-reads the dataset, then records the
    /// manifest change. When anything after the zip write fails, the zip goes
    /// back to `previous` (or loses the new entry when there was none), so a
    /// failed attach never leaves the pool behind as a plain support file and
    /// a failed update never leaves new bytes under an old version's source.
    private static func writeThenRecord(
        _ write: PinnedWrite, setup: APITestSetup, on db: any Database,
        _ mutate: (inout TestProperties) throws -> Void
    ) async throws {
        // Checked before the write too, so the common race costs no rollback.
        _ = try await liveVersion(of: write.dataset, number: write.version, on: db)
        try await mutateSetupZip(zipPath: setup.zipPath, writes: [write.filename: write.bytes], deletions: [])
        do {
            _ = try await liveVersion(of: write.dataset, number: write.version, on: db)
            try await mutateManifest(setup: setup, on: db, mutate)
        } catch {
            if let previous = write.previous {
                try? await mutateSetupZip(zipPath: setup.zipPath, writes: [write.filename: previous], deletions: [])
            } else {
                try? await mutateSetupZip(zipPath: setup.zipPath, writes: [:], deletions: [write.filename])
            }
            throw error
        }
    }

    /// One file write that pins a dataset version, with the bytes to put back
    /// when the write cannot be recorded.
    private struct PinnedWrite {
        let filename: String
        let bytes: Data
        /// The file's bytes before the write, or nil when it is new.
        let previous: Data?
        let dataset: APICourseDataset
        let version: Int
    }

    /// The save-time checks of every dataset door, against the bytes the spec
    /// will deliver from.
    private static func requireValid(_ spec: DatasetSpec, bytes: Data) throws {
        if let size = spec.sampleSize, size < 1 {
            throw CourseDatasetError.attachmentIssue("A sample needs at least 1 row per student.")
        }
        if spec.sampleSize == nil, spec.stratumColumn != nil {
            throw CourseDatasetError.attachmentIssue(
                "'\(spec.file)': balancing across a column needs a sample size. The whole file has every category.")
        }
        if let issue = DatasetSpecValidation.issue(with: spec, sourceCSV: String(data: bytes, encoding: .utf8)) {
            throw CourseDatasetError.attachmentIssue(issue)
        }
    }
}

extension CourseDatasetService {

    /// `manifestText` with the library sources that do not resolve in
    /// `courseID` removed (`reconciledLibraryFields`). The text is returned
    /// unchanged, byte for byte, when no spec carries a library field or when
    /// every one resolves, so the manifest hash does not move.
    static func reconciledManifestText(
        _ manifestText: String, courseID: UUID, zipPath: String, on db: any Database
    ) async throws -> String {
        guard let props = decodeManifest(fromJSON: manifestText),
            props.datasets.contains(where: { $0.source != nil || $0.scope != .assignment })
        else { return manifestText }
        let (reconciled, dropped) = try await reconciledLibraryFields(
            props, courseID: courseID, zipPath: zipPath, on: db)
        guard !dropped.isEmpty else { return manifestText }
        return try encodeManifest(reconciled)
    }
}

extension DatasetSpec {
    /// This spec with `scope` in place of its own.
    fileprivate func withScope(_ scope: DatasetSliceScope) -> DatasetSpec {
        DatasetSpec(
            file: file, kind: kind, sampleSize: sampleSize, stratumColumn: stratumColumn, transforms: transforms,
            source: source, scope: scope)
    }
}
