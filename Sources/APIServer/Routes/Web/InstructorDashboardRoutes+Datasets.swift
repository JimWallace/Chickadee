// APIServer/Routes/Web/InstructorDashboardRoutes+Datasets.swift
//
// The instructor Datasets tab: the active course's dataset library
// (docs/datasets-course-library.md §4.5).
//
//   GET  /instructor/datasets                         → InstructorDatasetsPage
//   POST /instructor/datasets                         → create from an upload → the dataset page
//   GET  /instructor/datasets/view?slug=              → InstructorDatasetPage
//   GET  /instructor/datasets/download?slug=&version= → the bytes of one version
//   POST /instructor/datasets/metadata                → name, description, provenance, licence
//   POST /instructor/datasets/dictionary              → the column prose, or the FHIR entries and example
//   POST /instructor/datasets/versions                → a new version from an upload
//   POST /instructor/datasets/publish                 → publish or unpublish
//   POST /instructor/datasets/delete                  → delete a dataset that nothing attaches
//
// Each route names its dataset by slug in the active course, so a slug of
// another course is not found. The `/instructor` gate admits course staff to
// read. Every write needs a TA or above in a course that is not archived,
// because a dataset is content, as a content item is. Every write that
// succeeds records one audit row (#2724).

import Core
import Elementary
import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

extension InstructorDashboardRoutes {

    /// The upload body of a create: one file and the dataset's names.
    private struct CreateDatasetForm: Content {
        var name: String?
        var slug: String?
        /// A `DatasetFormat` raw value; absent means CSV.
        var format: String?
        var note: String?
        var file: File?
    }

    private struct AddVersionForm: Content {
        var slug: String?
        var note: String?
        var file: File?
    }

    private struct MetadataForm: Content {
        var slug: String?
        var name: String?
        var description: String?
        var provenance: String?
        var licence: String?
    }

    /// Parallel arrays, one entry per column in header order. A FHIR
    /// dataset posts its types, its codes and the example pick instead
    /// (`FHIRDictionarySection`).
    private struct DictionaryForm: Content {
        var slug: String?
        var version: Int?
        var columnNames: [String]?
        var columnDescriptions: [String]?
        var columnUnits: [String]?
        var typeNames: [String]?
        var typeDescriptions: [String]?
        var codeTypes: [String]?
        var codeSystems: [String]?
        var codeCodes: [String]?
        var codeDescriptions: [String]?
        var exampleType: String?
        var exampleID: String?
    }

    private struct SlugForm: Content {
        var slug: String?
        /// "1" to publish, anything else to unpublish.
        var published: String?
    }

    /// The Datasets tab routes, under the `/instructor` group.
    func registerDatasetRoutes(on r: any RoutesBuilder) {
        r.get("datasets", use: datasetsPage)
        r.on(.POST, "datasets", body: .collect(maxSize: "17mb"), use: createDataset)
        r.get("datasets", "view", use: datasetPage)
        r.get("datasets", "download", use: downloadDatasetVersion)
        r.post("datasets", "metadata", use: saveDatasetMetadata)
        r.post("datasets", "dictionary", use: saveDatasetDictionary)
        r.on(.POST, "datasets", "versions", body: .collect(maxSize: "17mb"), use: addDatasetVersion)
        r.post("datasets", "publish", use: publishDataset)
        r.post("datasets", "delete", use: deleteDataset)
    }

    // MARK: - Pages

    @Sendable
    func datasetsPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let course = try await activeDatasetCourse(req: req, user: user)
        var rows: [InstructorDatasetRow] = []
        if let courseID = course?.id {
            let datasets = try await CourseDatasetService.list(courseID: courseID, on: req.db)
            let newest = try await CourseDatasetService.newestVersions(of: datasets, on: req.db)
            let usage = try await CourseDatasetService.usageCounts(courseID: courseID, on: req.db)
            rows = try datasets.map { dataset in
                InstructorDatasetRow(
                    dataset: dataset, newest: newest[try dataset.requireID()], usageCount: usage[dataset.slug] ?? 0)
            }
        }
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorDatasetsPage(
                page: page, flash: Self.datasetFlash(req), hasActiveCourse: course != nil,
                courseCode: course?.code ?? "", datasets: rows,
                maxUploadText: formatBytes(CourseDatasetService.maxVersionBytes))
        }.encodeResponse(for: req)
    }

    @Sendable
    func datasetPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let dataset = try await requireDataset(
            req.query[String.self, at: "slug"], courseID: activeDatasetCourse(req: req, user: user)?.id, on: req.db)
        let versions = try await CourseDatasetService.versions(of: dataset, on: req.db)
        let usage = try await CourseDatasetService.usage(of: dataset, on: req.db)
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorDatasetPage(
                page: page, flash: Self.datasetFlash(req),
                dataset: InstructorDatasetDetail(dataset: dataset, versions: versions, usage: usage),
                maxUploadText: formatBytes(CourseDatasetService.maxVersionBytes))
        }.encodeResponse(for: req)
    }

    @Sendable
    func downloadDatasetVersion(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let dataset = try await requireDataset(
            req.query[String.self, at: "slug"], courseID: activeDatasetCourse(req: req, user: user)?.id, on: req.db)
        var number = dataset.currentVersion
        if let raw = req.query[String.self, at: "version"] {
            guard let parsed = Int(raw) else { throw AppError.badRequest(reason: "The version is not a number.") }
            number = parsed
        }
        guard let version = try await CourseDatasetService.version(number, of: dataset, on: req.db) else {
            throw AppError.notFound(resource: "Dataset version")
        }
        let bytes = try CourseDatasetService.bytes(of: version, blobs: datasetBlobs(req))
        let response = Response(status: .ok, body: .init(data: bytes))
        let format = dataset.format
        response.headers.replaceOrAdd(name: .contentType, value: "\(format.mediaType); charset=utf-8")
        // The slug passed `validatedSlug`, so it needs no quoting, and the
        // slug and version keep two downloads apart. The extension is the
        // dataset's format (docs/fhir-datasets-plan.md §3).
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(dataset.slug)-v\(version.version).\(format.fileExtension)\"")
        return response
    }

    // MARK: - Writes

    @Sendable
    func createDataset(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(CreateDatasetForm.self)
        let name = form.name ?? ""
        // A blank slug is made from the name.
        let typedSlug = (form.slug ?? "").trimmingCharacters(in: .whitespaces)
        let slug = typedSlug.isEmpty ? CourseDatasetService.suggestedSlug(from: name) : typedSlug
        guard let file = form.file, file.data.readableBytes > 0 else {
            return Self.redirectToList(req: req, error: "Choose a file to upload.")
        }
        guard let format = DatasetFormat(rawValue: form.format ?? DatasetFormat.csv.rawValue) else {
            return Self.redirectToList(req: req, error: "Choose CSV or FHIR NDJSON as the format.")
        }
        do {
            let created = try await CourseDatasetService.create(
                courseID: courseID,
                dataset: .init(name: name, slug: slug, format: format),
                upload: .init(filename: file.filename, bytes: Data(buffer: file.data), note: form.note),
                blobs: datasetBlobs(req), on: req.db)
            await AuditLogger.recordDatasetWrite(
                .datasetCreated, dataset: created.dataset, metadata: ["version": "\(created.version.version)"], on: req)
            return Self.redirectToDataset(req: req, slug: created.dataset.slug, notice: "Created.")
        } catch let error as CourseDatasetError {
            return Self.redirectToList(req: req, error: error.description)
        }
    }

    @Sendable
    func addDatasetVersion(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(AddVersionForm.self)
        let dataset = try await requireDataset(form.slug, courseID: courseID, on: req.db)
        guard let file = form.file, file.data.readableBytes > 0 else {
            return Self.redirectToDataset(
                req: req, slug: dataset.slug, error: "Choose a \(dataset.format.displayName) file to upload.")
        }
        do {
            let added = try await CourseDatasetService.addVersion(
                to: dataset,
                upload: .init(filename: file.filename, bytes: Data(buffer: file.data), note: form.note),
                blobs: datasetBlobs(req), on: req.db)
            await AuditLogger.recordDatasetWrite(
                .datasetVersionAdded, dataset: dataset, metadata: ["version": "\(added.version.version)"], on: req)
            var notice = "Added version \(added.version.version)."
            if !added.droppedColumns.isEmpty {
                notice += " The new file has no \(added.droppedColumns.joined(separator: ", ")) column."
            }
            if dataset.format == .fhirNdjson {
                // Prose carries by type and code, so a code whose meaning
                // changed keeps its old description until it is edited.
                notice += " Descriptions carried over by type and code; check them in the dictionary."
            }
            return Self.redirectToDataset(req: req, slug: dataset.slug, notice: notice)
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    @Sendable
    func saveDatasetMetadata(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(MetadataForm.self)
        let dataset = try await requireDataset(form.slug, courseID: courseID, on: req.db)
        // Every field is in the form, so an empty field clears the value.
        let edit = CourseDatasetService.MetadataEdit(
            name: form.name ?? "", description: form.description ?? "", provenance: form.provenance ?? "",
            licence: form.licence ?? "")
        do {
            try await CourseDatasetService.updateMetadata(dataset, edit: edit, on: req.db)
            await AuditLogger.recordDatasetWrite(.datasetMetadataChanged, dataset: dataset, on: req)
            return Self.redirectToDataset(req: req, slug: dataset.slug, notice: "Saved.")
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    @Sendable
    func saveDatasetDictionary(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(DictionaryForm.self)
        let dataset = try await requireDataset(form.slug, courseID: courseID, on: req.db)
        if dataset.format == .fhirNdjson {
            return try await saveFHIRDictionary(req: req, dataset: dataset, form: form)
        }
        let names = form.columnNames ?? []
        let descriptions = form.columnDescriptions ?? []
        let units = form.columnUnits ?? []
        guard descriptions.count == names.count, units.count == names.count else {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: "The dictionary form was incomplete.")
        }
        let notes = names.indices.map { index in
            CourseDatasetService.ColumnNote(name: names[index], description: descriptions[index], unit: units[index])
        }
        do {
            let version = form.version ?? dataset.currentVersion
            _ = try await CourseDatasetService.updateDictionary(dataset, version: version, notes: notes, on: req.db)
            await AuditLogger.recordDatasetWrite(
                .datasetDictionaryChanged, dataset: dataset, metadata: ["version": "\(version)"], on: req)
            return Self.redirectToDataset(req: req, slug: dataset.slug, notice: "Saved.")
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    /// The FHIR dictionary: every type and code with its prose, and the
    /// example pick when it changed.
    private func saveFHIRDictionary(
        req: Request, dataset: APICourseDataset, form: DictionaryForm
    ) async throws -> Response {
        let typeNames = form.typeNames ?? []
        let typeDescriptions = form.typeDescriptions ?? []
        let codeTypes = form.codeTypes ?? []
        let codeSystems = form.codeSystems ?? []
        let codeCodes = form.codeCodes ?? []
        let codeDescriptions = form.codeDescriptions ?? []
        guard typeDescriptions.count == typeNames.count,
            [codeSystems.count, codeCodes.count, codeDescriptions.count].allSatisfy({ $0 == codeTypes.count })
        else {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: "The dictionary form was incomplete.")
        }
        let version = form.version ?? dataset.currentVersion
        var edit = CourseDatasetService.FHIRDictionaryEdit(replacingOthers: true)
        edit.types = typeNames.indices.map { (typeNames[$0], typeDescriptions[$0]) }
        edit.codes = codeTypes.indices.map { index in
            let system = codeSystems[index]
            let key = FHIRDatasetSummary.CodeKey(
                resourceType: codeTypes[index], system: system.isEmpty ? nil : system, code: codeCodes[index])
            return (key, codeDescriptions[index])
        }
        let pickType = (form.exampleType ?? "").trimmingCharacters(in: .whitespaces)
        let pickID = (form.exampleID ?? "").trimmingCharacters(in: .whitespaces)
        // The descriptions are saved first and the example pick second, so a
        // pick the file lacks does not throw away the prose typed beside it.
        // The two writes are not one transaction on purpose: the message
        // says the descriptions are saved when only the pick is refused.
        do {
            let current = try await CourseDatasetService.version(version, of: dataset, on: req.db)?.summary?.example
            _ = try await CourseDatasetService.updateFHIRDictionary(
                dataset, version: version, edit: edit, blobs: datasetBlobs(req), on: req.db)
            await AuditLogger.recordDatasetWrite(
                .datasetDictionaryChanged, dataset: dataset, metadata: ["version": "\(version)"], on: req)
            guard !pickType.isEmpty, !pickID.isEmpty, pickType != current?.resourceType || pickID != current?.id
            else {
                return Self.redirectToDataset(req: req, slug: dataset.slug, notice: "Saved.")
            }
            do {
                var pick = CourseDatasetService.FHIRDictionaryEdit(replacingOthers: false)
                pick.example = (pickType, pickID)
                _ = try await CourseDatasetService.updateFHIRDictionary(
                    dataset, version: version, edit: pick, blobs: datasetBlobs(req), on: req.db)
                return Self.redirectToDataset(req: req, slug: dataset.slug, notice: "Saved.")
            } catch let error as CourseDatasetError {
                return Self.redirectToDataset(
                    req: req, slug: dataset.slug, error: "The descriptions are saved. \(error.description)")
            }
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    @Sendable
    func publishDataset(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(SlugForm.self)
        let dataset = try await requireDataset(form.slug, courseID: courseID, on: req.db)
        let published = form.published == "1"
        do {
            try await CourseDatasetService.setPublished(dataset, published, on: req.db)
            await AuditLogger.recordDatasetWrite(
                .datasetVisibilityChanged, dataset: dataset, metadata: ["published": "\(published)"], on: req)
            return Self.redirectToDataset(
                req: req, slug: dataset.slug, notice: published ? "Published." : "Unpublished.")
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    @Sendable
    func deleteDataset(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseID = try await requireDatasetWrite(req: req, user: user)
        let form = try await req.decodeContent(SlugForm.self)
        let dataset = try await requireDataset(form.slug, courseID: courseID, on: req.db)
        do {
            try await CourseDatasetService.delete(dataset, on: req.db)
            await AuditLogger.recordDatasetWrite(.datasetDeleted, dataset: dataset, on: req)
            return Self.redirectToList(req: req, notice: "Deleted \(dataset.name).")
        } catch let error as CourseDatasetError {
            return Self.redirectToDataset(req: req, slug: dataset.slug, error: error.description)
        }
    }

    // MARK: - Helpers

    /// The active course. The `/instructor` gate admits only its staff, and
    /// an archived course is never the active course, so a reader may also
    /// write; each write still checks the floor itself.
    private func activeDatasetCourse(req: Request, user: APIUser) async throws -> APICourse? {
        try await req.activeCourseRow(for: user)
    }

    /// The active course, after the TA floor and the archive check.
    private func requireDatasetWrite(req: Request, user: APIUser) async throws -> UUID {
        try await req.requireActiveCourseForWrite(
            user, atLeast: CourseRoleFloor.manageCourseDatasets, action: "managing datasets"
        ).requireID()
    }

    /// The dataset with `slug` in `courseID`, the active course. A slug of
    /// another course is not found.
    private func requireDataset(
        _ slug: String?, courseID: UUID?, on db: any Database
    ) async throws -> APICourseDataset {
        guard let courseID, let slug,
            let dataset = try await CourseDatasetService.find(courseID: courseID, slug: slug, on: db)
        else {
            throw AppError.notFound(resource: "Dataset")
        }
        return dataset
    }

    private func datasetBlobs(_ req: Request) -> AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: req.application.testSetupsDirectory)
    }

    private static func datasetFlash(_ req: Request) -> FlashMessages {
        FlashMessages(success: req.query[String.self, at: "notice"], error: req.query[String.self, at: "error"])
    }

    private static func redirectToList(req: Request, notice: String? = nil, error: String? = nil) -> Response {
        req.redirect(to: "/instructor/datasets" + flashQuery(notice: notice, error: error, joiner: "?"))
    }

    private static func redirectToDataset(
        req: Request, slug: String, notice: String? = nil, error: String? = nil
    ) -> Response {
        req.redirect(
            to: "/instructor/datasets/view?slug=\(urlEncode(slug))"
                + flashQuery(notice: notice, error: error, joiner: "&"))
    }

    private static func flashQuery(notice: String?, error: String?, joiner: String) -> String {
        if let error { return "\(joiner)error=\(urlEncode(error))" }
        if let notice { return "\(joiner)notice=\(urlEncode(notice))" }
        return ""
    }
}
