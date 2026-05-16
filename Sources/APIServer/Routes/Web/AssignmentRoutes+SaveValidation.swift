// APIServer/Routes/Web/AssignmentRoutes+SaveValidation.swift
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
/// multipart body.  Each field has been resolved across the
/// "many" (`suiteFiles[]`) / "single" (`suiteFiles`) decode paths;
/// validation (e.g. "title is required", "notebook must be JSON") happens
/// later, in `validateSaveNewAssignment`.
struct SaveNewAssignmentForm {
    let assignmentName: String?
    let dueAtRaw: String?
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

extension AssignmentRoutes {

    // MARK: - Multipart fan-in

    /// Parses the save-new-assignment body across both the array-typed
    /// (`suiteFiles[]`) and single-typed (`suiteFiles`) Vapor decode paths
    /// and returns the fields a typed handler would expect.  Throws
    /// `WebAssignmentError.invalidParameter` when neither decode path
    /// recognises the body.
    func parseSaveNewAssignmentForm(req: Request) throws -> SaveNewAssignmentForm {
        struct SaveBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var draftID: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
            var requiredPlatform: String?
            var requiredArchitecture: String?
            var requiredLanguagesCSV: String?
            var requiredCapabilitiesCSV: String?
        }
        struct SaveBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var draftID: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
            var requiredPlatform: String?
            var requiredArchitecture: String?
            var requiredLanguagesCSV: String?
            var requiredCapabilitiesCSV: String?
        }

        let bodyMany = try? req.content.decode(SaveBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(SaveBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid assignment upload payload"
            )
        }

        let suiteFilesRaw =
            try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? bodyMany?.suiteFiles
            ?? (bodySingle?.suiteFiles.map { [$0] } ?? [])

        return SaveNewAssignmentForm(
            assignmentName: try multipartTextField(named: ["assignmentName"], from: req)
                ?? bodyMany?.assignmentName ?? bodySingle?.assignmentName,
            dueAtRaw: try multipartTextField(named: ["dueAt"], from: req)
                ?? bodyMany?.dueAt ?? bodySingle?.dueAt,
            sectionIDRaw: try multipartTextField(named: ["sectionID"], from: req)
                ?? bodyMany?.sectionID ?? bodySingle?.sectionID,
            draftIDRaw: try multipartTextField(named: ["draftID"], from: req)
                ?? bodyMany?.draftID ?? bodySingle?.draftID,
            assignmentNotebookFile: bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile,
            solutionNotebookFile: bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile,
            suiteFilesRaw: suiteFilesRaw,
            suiteConfigRaw: try multipartTextField(named: ["suiteConfig"], from: req)
                ?? bodyMany?.suiteConfig ?? bodySingle?.suiteConfig,
            requiredPlatform: try multipartTextField(named: ["requiredPlatform"], from: req)
                ?? bodyMany?.requiredPlatform ?? bodySingle?.requiredPlatform ?? "",
            requiredArchitecture: try multipartTextField(named: ["requiredArchitecture"], from: req)
                ?? bodyMany?.requiredArchitecture ?? bodySingle?.requiredArchitecture ?? "",
            requiredLanguagesCSV: try multipartTextField(named: ["requiredLanguagesCSV"], from: req)
                ?? bodyMany?.requiredLanguagesCSV ?? bodySingle?.requiredLanguagesCSV ?? "",
            requiredCapabilitiesCSV: try multipartTextField(named: ["requiredCapabilitiesCSV"], from: req)
                ?? bodyMany?.requiredCapabilitiesCSV ?? bodySingle?.requiredCapabilitiesCSV ?? ""
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
        let draftID = (form.draftIDRaw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let draftSetup = draftID.isEmpty ? nil : try await APITestSetup.find(draftID, on: req.db)
        let draftState =
            draftSetup == nil
            ? NewAssignmentDraftFormState.empty
            : loadDraftFormState(req: req, draftID: draftID)

        let dueAtRaw = form.dueAtRaw ?? ""
        let sectionIDRaw = form.sectionIDRaw ?? ""

        guard !title.isEmpty else {
            return .redirect(
                toURL: newAssignmentErrorRedirect(
                    title: "",
                    dueAt: dueAtRaw,
                    sectionID: sectionIDRaw,
                    draftID: draftID,
                    error: "Assignment name is required"
                ))
        }

        let suiteFiles = form.suiteFilesRaw.filter { $0.data.readableBytes > 0 }

        let uploadedAssignmentNotebookFilename: String? = {
            guard let f = form.assignmentNotebookFile, f.data.readableBytes > 0 else { return nil }
            return f.filename
        }()
        let uploadedSolutionNotebookFilename: String? = {
            guard let f = form.solutionNotebookFile, f.data.readableBytes > 0 else { return nil }
            return f.filename
        }()

        let assignmentNotebookRaw: Data = {
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
        }()
        guard !assignmentNotebookRaw.isEmpty else {
            return .redirect(
                toURL: newAssignmentErrorRedirect(
                    title: title, dueAt: dueAtRaw, sectionID: sectionIDRaw, draftID: draftID,
                    error: "Assignment notebook (.ipynb) is required"
                ))
        }

        let solutionNotebookRaw: Data = {
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
        }()
        guard !solutionNotebookRaw.isEmpty else {
            return .redirect(
                toURL: newAssignmentErrorRedirect(
                    title: title, dueAt: dueAtRaw, sectionID: sectionIDRaw, draftID: draftID,
                    error: "Solution notebook (.ipynb) is required"
                ))
        }
        guard (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            return .redirect(
                toURL: newAssignmentErrorRedirect(
                    title: title, dueAt: dueAtRaw, sectionID: sectionIDRaw, draftID: draftID,
                    error: "Assignment notebook is not valid JSON (.ipynb)"
                ))
        }
        guard (try? JSONSerialization.jsonObject(with: solutionNotebookRaw)) != nil else {
            return .redirect(
                toURL: newAssignmentErrorRedirect(
                    title: title, dueAt: dueAtRaw, sectionID: sectionIDRaw, draftID: draftID,
                    error: "Solution notebook is not valid JSON (.ipynb)"
                ))
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

    // MARK: - Error redirect builder

    /// Builds the `/instructor/new?…` URL used to bounce the instructor
    /// back to the new-assignment page with a user-visible error.  All
    /// guarded fields (title, dueAt, sectionID, draftID) are preserved so
    /// the form re-renders with the values they typed.
    func newAssignmentErrorRedirect(
        title: String,
        dueAt: String,
        sectionID: String,
        draftID: String,
        error: String
    ) -> String {
        let q =
            "assignmentName=\(urlEncode(title))"
            + "&dueAt=\(urlEncode(dueAt))"
            + "&sectionID=\(urlEncode(sectionID))"
            + "&draftID=\(urlEncode(draftID))"
            + "&error=\(urlEncode(error))"
        return "/instructor/new?\(q)"
    }
}
