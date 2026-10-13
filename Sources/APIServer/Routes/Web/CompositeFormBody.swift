// APIServer/Routes/Web/CompositeFormBody.swift
//
// The posted fields of the edit page's class-composite form, read into a
// `CompositeSpec` (docs/class-composite.md, slice 2). Every field arrives as
// text. A structural field that is absent keeps the stored value, because a
// locked input renders disabled and is not posted.

import Core
import Vapor

struct CompositeFormBody: Content {
    var compositor: String?
    var cols: String?
    var rows: String?
    var count: String?
    var w: String?
    var h: String?
    var frames: String?
    var format: String?
    var dealOrder: String?
    var frameRate: String?
    /// Checkbox: "on" when checked, absent when not — absence is false.
    var showFailed: String?
    var emptySlots: String?

    /// A field that is present but cannot be read.
    struct Unreadable: Error {
        let message: String
    }

    /// The spec these fields describe, with `stored` supplying each
    /// structural field that is absent.
    func spec(keeping stored: CompositeSpec) throws -> CompositeSpec {
        let compositor = try Self.choice(compositor, CompositeCompositor.self, "compositor") ?? stored.compositor
        // The page shows only the stored compositor's layout fields, so the
        // posted fields apply to the stored shape first. A compositor change
        // between a grid and a count then reshapes that layout, keeping every
        // slot, and the next render shows the fields for the new shape.
        let posted: CompositeLayout
        switch stored.layout {
        case .grid(let storedColumns, let storedRows):
            posted = .grid(
                columns: try Self.number(cols, "columns") ?? storedColumns,
                rows: try Self.number(rows, "rows") ?? storedRows)
        case .count(let storedCount):
            posted = .count(try Self.number(count, "slot count") ?? storedCount)
        }
        let layout = posted.reshaped(forGrid: compositor.usesGrid)
        let contribution = CompositeContributionShape(
            width: try Self.number(w, "contribution width") ?? stored.contribution.width,
            height: try Self.number(h, "contribution height") ?? stored.contribution.height,
            frames: try Self.number(frames, "frame count") ?? stored.contribution.frames,
            format: try Self.choice(format, CompositePixelFormat.self, "pixel format") ?? stored.contribution.format)
        return CompositeSpec(
            compositor: compositor,
            layout: layout,
            contribution: contribution,
            dealOrder: try Self.choice(dealOrder, CompositeDealOrder.self, "deal order") ?? stored.dealOrder,
            frameRate: try Self.number(frameRate, "frame rate") ?? stored.frameRate,
            showFailed: showFailed != nil,
            emptySlots: try Self.choice(emptySlots, CompositeEmptySlots.self, "empty-slot setting")
                ?? stored.emptySlots)
    }

    /// Nil when the field is absent or blank; the whole number otherwise.
    private static func number(_ raw: String?, _ name: String) throws -> Int? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed) else {
            throw Unreadable(message: "The \(name) must be a whole number.")
        }
        return value
    }

    /// Nil when the field is absent or blank; the named case otherwise.
    private static func choice<Option: RawRepresentable>(
        _ raw: String?, _ type: Option.Type, _ name: String
    ) throws -> Option? where Option.RawValue == String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Option(rawValue: trimmed) else {
            throw Unreadable(message: "The \(name) \"\(trimmed)\" is not one this page offers.")
        }
        return value
    }
}
