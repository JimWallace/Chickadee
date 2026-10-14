// APIServer/Routes/Web/CompositeEditFacts.swift
//
// The edit page's class-composite settings (docs/class-composite.md, slice 2):
// the stored `CompositeSpec` as a detail grid of current values, the form
// that changes it, and the roster line that helps an instructor size the
// layout for the expected attendance.

import Core

struct CompositeEditFacts: Encodable {
    /// The input limits, from `CompositeSpec`, for the form's `max`
    /// attributes. The save refuses the same values the inputs do.
    static let maxGridSide = CompositeSpec.maxGridSide
    static let maxSlots = CompositeSpec.maxSlots
    static let maxContributionSide = CompositeSpec.maxContributionSide
    static let maxFrames = CompositeSpec.maxFrames
    static let maxFrameRate = CompositeSpec.maxFrameRate

    // MARK: Current values, for the detail grid

    let compositorLabel: String
    /// "8 columns × 6 rows (48 slots)" or "36 slots".
    let slotsLabel: String
    /// "8 × 8 px, 1 frame, RGB".
    let contributionLabel: String
    let dealOrderLabel: String
    let frameRateLabel: String
    let showFailedLabel: String
    let emptySlotsLabel: String

    // MARK: The form

    let compositorOptions: [SelectOption]
    /// True when the stored compositor takes a grid: the form shows Columns
    /// and Rows; otherwise it shows Slots. A compositor change that crosses
    /// the two keeps every slot (`CompositeLayout.reshaped(forGrid:)`), and
    /// the next render shows the fields for the new shape.
    let usesGrid: Bool
    let columns: String
    let rows: String
    let count: String
    let width: String
    let height: String
    let frames: String
    let formatOptions: [SelectOption]
    let dealOrderOptions: [SelectOption]
    let frameRate: String
    let showFailed: Bool
    let emptySlotsOptions: [SelectOption]
    /// True once a student has submitted: the structural inputs render
    /// disabled, and a disabled input is not posted, so the endpoint keeps
    /// the stored value for each (`ActivityAuthoring.compositeLayoutLockedMessage`).
    let structureLocked: Bool
    /// "Roster: 62. Slots: 48 (77%)." — the slot count as a share of the
    /// enrolled students. Size the layout for the attendance you expect.
    let rosterLine: String
    /// "Not prepared", or "31 of 48 slots ready": the reference render
    /// (docs/class-composite.md, slice 6).
    var referenceLabel = "Not prepared"

    static func make(
        spec: CompositeSpec, enrolledStudents: Int, locked: Bool, referenceProgress: (ready: Int, total: Int)? = nil
    ) -> CompositeEditFacts {
        let shape = spec.contribution
        let columns: Int?
        let rows: Int?
        let count: Int?
        let slotsLabel: String
        switch spec.layout {
        case .grid(let c, let r):
            (columns, rows, count) = (c, r, nil)
            slotsLabel = "\(c) columns × \(r) rows (\(c * r) slots)"
        case .count(let n):
            (columns, rows, count) = (nil, nil, n)
            slotsLabel = "\(n) slots"
        }
        return CompositeEditFacts(
            compositorLabel: spec.compositor.displayName,
            slotsLabel: slotsLabel,
            contributionLabel:
                "\(shape.width) × \(shape.height) px, \(shape.frames) "
                + (shape.frames == 1 ? "frame" : "frames") + ", \(formatLabel(shape.format))",
            dealOrderLabel: spec.dealOrder.displayName,
            frameRateLabel: "\(spec.frameRate) fps",
            showFailedLabel: spec.showFailed ? "Shown with a mark" : "Hidden",
            emptySlotsLabel: spec.emptySlots.displayName,
            compositorOptions: CompositeCompositor.allCases.map {
                SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == spec.compositor)
            },
            usesGrid: spec.compositor.usesGrid,
            columns: columns.map(String.init) ?? "",
            rows: rows.map(String.init) ?? "",
            count: count.map(String.init) ?? "",
            width: String(shape.width),
            height: String(shape.height),
            frames: String(shape.frames),
            formatOptions: CompositePixelFormat.allCases.map {
                SelectOption(value: $0.rawValue, label: formatLabel($0), selected: $0 == shape.format)
            },
            dealOrderOptions: CompositeDealOrder.allCases.map {
                SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == spec.dealOrder)
            },
            frameRate: String(spec.frameRate),
            showFailed: spec.showFailed,
            emptySlotsOptions: CompositeEmptySlots.allCases.map {
                SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == spec.emptySlots)
            },
            structureLocked: locked,
            rosterLine: rosterLine(slots: spec.layout.slotCount, enrolledStudents: enrolledStudents),
            referenceLabel: referenceProgress.map { "\($0.ready) of \($0.total) slots ready" } ?? "Not prepared")
    }

    /// "Roster: 62. Slots: 48 (77%)." With nobody enrolled there is no share
    /// to state, so the percentage is left out.
    static func rosterLine(slots: Int, enrolledStudents: Int) -> String {
        guard enrolledStudents > 0 else { return "Roster: 0. Slots: \(slots)." }
        let percent = Int((Double(slots) / Double(enrolledStudents) * 100).rounded())
        return "Roster: \(enrolledStudents). Slots: \(slots) (\(percent)%)."
    }

    /// The pixel format's label. Kept here rather than on the RunnerCore
    /// enum: RunnerCore compiles to the browser wasm, and a label is page copy.
    static func formatLabel(_ format: CompositePixelFormat) -> String {
        switch format {
        case .gray8: return "Grey"
        case .rgb8: return "RGB"
        }
    }
}
