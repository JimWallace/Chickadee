// APIServer/Routes/Web/DraftAssignmentRoutes+SaveValidation.swift
//
// Multipart-form parsing + validation helpers for `POST /instructor/new/save`
// (`AssignmentRoutes.saveNewAssignment`).  Split out per #443: the original
// handler had ~10 copy-pasted error redirects that built the same URL by
// hand and ~80 lines of multipart fan-in logic before any business logic
// ran.  These helpers consolidate that into one parser + one redirect
// builder so the handler can focus on the actual save.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Parsed form payload

/// Raw + lightly normalised values extracted from the save-new-assignment
/// multipart body.  `suiteFiles` has been resolved across the
/// "many" (`suiteFiles[]`) / "single" (`suiteFiles`) shapes via
/// `MultipartFileList`; validation (e.g. "title is required", "notebook
/// must be JSON") happens later, in `validateSaveNewAssignment`.
struct SaveNewAssignmentForm {
    let assignmentName: String?
    let dueAtRaw: String?
    let startsAtRaw: String?
    let sectionIDRaw: String?
    let draftIDRaw: String?
    let assignmentNotebookFile: File?
    let solutionNotebookFile: File?
    let suiteFilesRaw: [File]
    let suiteConfigRaw: String?
    let requiredPlatform: String
    let requiredArchitecture: String
    let requiredLanguagesCSV: String
    let requiredCapabilitiesCSV: String
}

/// Outcome of validating a `SaveNewAssignmentForm` — either a fully
/// resolved bundle ready for the save path, or a redirect-back URL with
/// the user-visible error already encoded.  Modelled as a custom enum
/// rather than `Result<…, Error>` because the failure isn't an exception:
/// it's a normal "user input was invalid, send them back to the form"
/// outcome and the handler just `req.redirect(to: url)`.
enum SaveNewAssignmentValidation {
    case valid(ValidatedSaveNewAssignment)
    case redirect(toURL: String)
}

/// All fields the save-new-assignment handler validated and resolved.
/// Reaching the `.valid` arm of `validateSaveNewAssignment` means every
/// guard passed, so the handler can use these directly without
/// re-checking.
struct ValidatedSaveNewAssignment {
    let title: String
    let dueAt: Date?
    let dueAtRaw: String
    let sectionIDRaw: String
    let startsAt: Date?
    let startsAtRaw: String
    let draftID: String
    let draftSetup: APITestSetup?
    let draftState: NewAssignmentDraftFormState
    let assignmentNotebookRaw: Data
    let solutionNotebookRaw: Data
    let uploadedAssignmentNotebookFilename: String?
    let uploadedSolutionNotebookFilename: String?
    let suiteFiles: [File]
    let suiteConfigRaw: String?
    let requirementSpec: AssignmentRequirementSpec?
}

extension DraftAssignmentRoutes {

    // MARK: - Multipart fan-in

    /// Parses the save-new-assignment body — `suiteFiles` decodes both the
    /// array-typed (`suiteFiles[]`) and single-bare-`File` (Safari) shapes
    /// via `MultipartFileList` — and returns the fields a typed handler
    /// would expect.  Throws `WebAssignmentError.invalidParameter` when the
    /// body isn't recognised.
    func parseSaveNewAssignmentForm(req: Request) throws -> SaveNewAssignmentForm {
        struct SaveBody: Content {
            var assignmentName: String?
            var dueAt: String?
            var startsAt: String?
            var sectionID: String?
            var draftID: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: MultipartFileList?
            var suiteConfig: String?
            var requiredPlatform: String?
            var requiredArchitecture: String?
            var requiredLanguagesCSV: String?
            var requiredCapabilitiesCSV: String?
        }

        guard let body = try? req.content.decode(SaveBody.self) else {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid assignment upload payload"
            )
        }

        let suiteFilesRaw =
            try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? body.suiteFiles?.files
            ?? []

        return SaveNewAssignmentForm(
            assignmentName: try multipartTextField(named: ["assignmentName"], from: req)
                ?? body.assignmentName,
            dueAtRaw: try multipartTextField(named: ["dueAt"], from: req)
                ?? body.dueAt,
            startsAtRaw: try multipartTextField(named: ["startsAt"], from: req)
                ?? body.startsAt,
            sectionIDRaw: try multipartTextField(named: ["sectionID"], from: req)
                ?? body.sectionID,
            draftIDRaw: try multipartTextField(named: ["draftID"], from: req)
                ?? body.draftID,
            assignmentNotebookFile: body.assignmentNotebookFile,
            solutionNotebookFile: body.solutionNotebookFile,
            suiteFilesRaw: suiteFilesRaw,
            suiteConfigRaw: try multipartTextField(named: ["suiteConfig"], from: req)
                ?? body.suiteConfig,
            requiredPlatform: try multipartTextField(named: ["requiredPlatform"], from: req)
                ?? body.requiredPlatform ?? "",
            requiredArchitecture: try multipartTextField(named: ["requiredArchitecture"], from: req)
                ?? body.requiredArchitecture ?? "",
            requiredLanguagesCSV: try multipartTextField(named: ["requiredLanguagesCSV"], from: req)
                ?? body.requiredLanguagesCSV ?? "",
            requiredCapabilitiesCSV: try multipartTextField(named: ["requiredCapabilitiesCSV"], from: req)
                ?? body.requiredCapabilitiesCSV ?? ""
        )
    }

    // MARK: - Validation

    /// Resolves and validates a parsed `SaveNewAssignmentForm`.  Returns
    /// `.valid(ValidatedSaveNewAssignment)` when every requirement is
    /// satisfied, or `.redirect(toURL:)` carrying the location string for
    /// a redirect back to the new-assignment page with a user-visible
    /// error in the query string.
    func validateSaveNewAssignment(
        req: Request,
        saveUserID: UUID?,
        form: SaveNewAssignmentForm
    ) async throws -> SaveNewAssignmentValidation {
        let title = (form.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(form.dueAtRaw)
        let starts = parseDueDate(form.startsAtRaw)
        let draftID = (form.draftIDRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSetup = draftID.isEmpty ? nil : try await APITestSetup.find(draftID, on: req.db)
        let draftState =
            draftSetup == nil
            ? NewAssignmentDraftFormState.empty
            : loadDraftFormState(req: req, draftID: draftID)

        let dueAtRaw = form.dueAtRaw ?? ""
        let startsAtRaw = form.startsAtRaw ?? ""
        let sectionIDRaw = form.sectionIDRaw ?? ""

        // The bounce-back context for every redirect below.  The title is
        // filled in from `title` rather than the raw field so a name that was
        // only whitespace comes back empty, as it did before.
        let formContext = NewAssignmentFormContext(
            title: title,
            dueAt: dueAtRaw,
            startsAt: startsAtRaw,
            sectionID: sectionIDRaw,
            draftID: draftID
        )

        guard !title.isEmpty else {
            return .redirect(toURL: formContext.redirectURL(error: "Assignment name is required"))
        }

        let suiteFiles = form.suiteFilesRaw.filter { $0.data.readableBytes > 0 }

        let uploadedAssignmentNotebookFilename = uploadedFilename(form.assignmentNotebookFile)
        let uploadedSolutionNotebookFilename = uploadedFilename(form.solutionNotebookFile)

        let assignmentNotebookRaw = resolvedDraftAssignmentNotebookData(
            req: req, form: form, draftSetup: draftSetup, saveUserID: saveUserID)
        if let earlyRedirect = redirectIfNotebookDataInvalid(
            data: assignmentNotebookRaw,
            isPresent: !assignmentNotebookRaw.isEmpty,
            form: formContext,
            missingError: "Assignment notebook (.ipynb) is required",
            invalidJSONError: "Assignment notebook is not valid JSON (.ipynb)"
        ) {
            return earlyRedirect
        }

        let solutionNotebookRaw = resolvedDraftSolutionNotebookData(
            req: req, form: form, draftSetup: draftSetup, saveUserID: saveUserID)
        if let earlyRedirect = redirectIfNotebookDataInvalid(
            data: solutionNotebookRaw,
            isPresent: !solutionNotebookRaw.isEmpty,
            form: formContext,
            missingError: "Solution notebook (.ipynb) is required",
            invalidJSONError: "Solution notebook is not valid JSON (.ipynb)"
        ) {
            return earlyRedirect
        }

        let requirementSpec = assignmentRequirementSpec(
            platform: form.requiredPlatform,
            architecture: form.requiredArchitecture,
            languagesCSV: form.requiredLanguagesCSV,
            capabilitiesCSV: form.requiredCapabilitiesCSV
        )

        return .valid(
            ValidatedSaveNewAssignment(
                title: title,
                dueAt: due,
                dueAtRaw: dueAtRaw,
                sectionIDRaw: sectionIDRaw,
                startsAt: starts,
                startsAtRaw: startsAtRaw,
                draftID: draftID,
                draftSetup: draftSetup,
                draftState: draftState,
                assignmentNotebookRaw: assignmentNotebookRaw,
                solutionNotebookRaw: solutionNotebookRaw,
                uploadedAssignmentNotebookFilename: uploadedAssignmentNotebookFilename,
                uploadedSolutionNotebookFilename: uploadedSolutionNotebookFilename,
                suiteFiles: suiteFiles,
                suiteConfigRaw: form.suiteConfigRaw,
                requirementSpec: requirementSpec
            ))
    }

    // MARK: - validateSaveNewAssignment helpers

    private func uploadedFilename(_ file: File?) -> String? {
        guard let f = file, f.data.readableBytes > 0 else { return nil }
        return f.filename
    }

    private func resolvedDraftAssignmentNotebookData(
        req: Request,
        form: SaveNewAssignmentForm,
        draftSetup: APITestSetup?,
        saveUserID: UUID?
    ) -> Data {
        if let f = form.assignmentNotebookFile, f.data.readableBytes > 0 {
            return Data(f.data.readableBytesView)
        }
        guard let draftSetup, let draftSetupID = draftSetup.id, let saveUserID else { return Data() }
        return draftNotebookData(
            req: req,
            setupID: draftSetupID,
            userID: saveUserID,
            fileKind: .assignment,
            fallbackPath: draftSetup.notebookPath
        ) ?? Data()
    }

    private func resolvedDraftSolutionNotebookData(
        req: Request,
        form: SaveNewAssignmentForm,
        draftSetup: APITestSetup?,
        saveUserID: UUID?
    ) -> Data {
        if let f = form.solutionNotebookFile, f.data.readableBytes > 0 {
            return Data(f.data.readableBytesView)
        }
        guard let draftSetup, let draftSetupID = draftSetup.id, let saveUserID else { return Data() }
        return draftNotebookData(
            req: req,
            setupID: draftSetupID,
            userID: saveUserID,
            fileKind: .solution,
            fallbackPath: draftSolutionNotebookPath(
                testSetupsDirectory: req.application.testSetupsDirectory,
                setupID: draftSetupID
            )
        ) ?? Data()
    }

    // Returns a `.redirect` validation result if the bytes are missing
    // or not valid JSON; otherwise nil.
    private func redirectIfNotebookDataInvalid(
        data: Data,
        isPresent: Bool,
        form: NewAssignmentFormContext,
        missingError: String,
        invalidJSONError: String
    ) -> SaveNewAssignmentValidation? {
        guard isPresent else {
            return .redirect(toURL: form.redirectURL(error: missingError))
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return .redirect(toURL: form.redirectURL(error: invalidJSONError))
        }
        return nil
    }
}
