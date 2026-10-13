// APIServer/Routes/Web/CompositeStagePresentation.swift
//
// What one class-composite stage needs to draw (docs/class-composite.md,
// slice 5): the spec as data attributes for `class-composite.js`, the CSS
// custom properties that size the frame and the slot cells, and either the
// URL of the JSON snapshot (the leaderboard and present mode) or one
// contribution's pixels (the student's own tile on the result page).

import Core
import Foundation

struct CompositeStagePresentation: Encodable {
    let spec: CompositeSpec
    /// The snapshot URL to poll; nil for a stage that draws `pixels` only.
    let snapshotURL: String?
    /// One contribution, for the student's own tile.
    let pixels: String?
    /// `passed` or `failed`, for the student's own tile.
    let pixelsState: String
    /// True on the staff page: each cell's title names its holder.
    let showsOwners: Bool
    /// When the session window closes, ISO 8601; the poll stops then. Empty
    /// for no window.
    var pollUntilISO = ""

    /// The staff leaderboard page, or present mode when `present` is true.
    static func board(spec: CompositeSpec, testSetupID: String, present: Bool, pollUntilISO: String?)
        -> CompositeStagePresentation
    {
        let url = "/testsetups/\(testSetupID)/composite" + (present ? "?present=1" : "")
        return CompositeStagePresentation(
            spec: spec, snapshotURL: url, pixels: nil, pixelsState: "", showsOwners: !present,
            pollUntilISO: pollUntilISO ?? "")
    }

    /// A student's own contribution: one slot at the contribution's size.
    static func ownTile(spec: CompositeSpec, pixels: String, passed: Bool) -> CompositeStagePresentation {
        let one = CompositeSpec(
            compositor: .tile, layout: .grid(columns: 1, rows: 1), contribution: spec.contribution,
            dealOrder: spec.dealOrder, frameRate: spec.frameRate, showFailed: true)
        return CompositeStagePresentation(
            spec: one, snapshotURL: nil, pixels: pixels, pixelsState: passed ? "passed" : "failed",
            showsOwners: false)
    }

    /// Columns and rows of the slot cells: the grid itself, or one strip of
    /// every slot under a sequence or a sum.
    var cellColumns: Int {
        if case .grid(let columns, _) = spec.layout { return columns }
        return spec.layout.slotCount
    }

    var cellRows: Int {
        if case .grid(_, let rows) = spec.layout { return rows }
        return 1
    }

    /// True when the cells lie over the canvas, one on each slot.
    var cellsOverlay: Bool { spec.compositor.usesGrid }

    /// Width over height of the drawn canvas.
    var aspectRatio: Double {
        let shape = spec.contribution
        let width = Double(shape.width * (cellsOverlay ? cellColumns : 1))
        let height = Double(shape.height * (cellsOverlay ? cellRows : 1))
        return width / height
    }

    /// The custom properties that size the frame and the cells.
    var styleProperties: String {
        let aspect = String(format: "%.4f", aspectRatio)
        return "--composite-cols: \(cellColumns); --composite-rows: \(cellRows); --composite-aspect: \(aspect)"
    }

    /// True when the view moves, so it needs playback controls: more than one
    /// tick in the shared clock (`ChickadeeCompositeCore.isAnimated`).
    var isAnimated: Bool {
        let frames = spec.contribution.frames
        return (spec.compositor == .sequence ? spec.layout.slotCount * frames : frames) > 1
    }
}
