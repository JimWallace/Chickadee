// APIServer/Utilities/WholeFileSampleReports.swift
//
// The two reports about a whole-file sample (docs/dataset-shared-delivery.md,
// "Whole-file samples"): one that a save normalized away, and one that is
// still stored. The MCP dataset tools and `check_assignment`
// (`WholeFileSampleCheck`) word them the same way from here.

/// One library spec that a save stored without its whole-file sample.
struct WholeFileSampleNormalization: Sendable, Equatable {
    let file: String
    let sampleSize: Int
    let dataRowCount: Int

    /// What happened, for an MCP result.
    var note: String {
        "'\(file)': a sample of \(sampleSize) rows covers all \(dataRowCount) data rows, so it is stored with no "
            + "sample size. Every student reads one linked copy of the whole file (datasetDelivery \"shared\"), "
            + "and so will a later, larger version; send a sampleSize again to sample one."
    }
}

/// A stored spec whose sample covers the whole file, so each student stores a
/// private copy of the same bytes.
struct WholeFilePerStudentSample: Sendable, Equatable {
    let file: String
    let sampleSize: Int
    let dataRowCount: Int
    let isLibraryAttachment: Bool

    /// The warning that the MCP dataset tools and `check_assignment` report.
    var message: String {
        "'\(file)': the sample of \(sampleSize) rows covers all \(dataRowCount) data rows, so every student "
            + "receives the whole file, but as a private copy (datasetDelivery \"perStudent\") rather than one "
            + "linked copy."
    }

    /// How to fix it. A file not attached from the library loses its
    /// dataset mark to the whole file, and with it its download link on an
    /// upload-only assignment's submit page, so that fix says so.
    var fix: String {
        isLibraryAttachment
            ? "Call set_dataset on '\(file)' with wholeFile: true, or clear the sample size in the Files panel."
            : "If students read '\(file)' in the editor, clear its dataset mark (set_dataset wholeFile: true, or "
                + "the Files panel): it then reaches them as one shared support file. Keep the mark on an "
                + "upload-only assignment, whose submit page offers only dataset files for download."
    }
}
