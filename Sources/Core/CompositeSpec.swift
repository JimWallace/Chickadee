// Core/CompositeSpec.swift
//
// The `composite` block of a class-composite activity (docs/class-composite.md,
// slice 2): how many slots the shared image has, what each contribution must
// look like, and how the projector shows it. The kind is `classComposite`; the
// block is meaningless on any other kind and is refused there at save.

/// How the projector combines the class's contributions into one image.
public enum CompositeCompositor: String, Codable, CaseIterable, Sendable {
    /// Each contribution at its grid position: each student shades one tile.
    case tile
    /// The contributions in slot order, as frames: a cine loop or a film.
    case sequence
    /// The contributions added pixel by pixel: one backprojected angle each.
    case sum
    /// The contributions side by side: one panel each.
    case gallery

    /// The select's label.
    public var displayName: String {
        switch self {
        case .tile: return "Tile"
        case .sequence: return "Sequence"
        case .sum: return "Sum"
        case .gallery: return "Gallery"
        }
    }

    /// True when the layout is a grid of columns and rows; false when it is
    /// a count of slots in order.
    public var usesGrid: Bool {
        switch self {
        case .tile, .gallery: return true
        case .sequence, .sum: return false
        }
    }
}

/// The order in which the server deals free slots to arriving students.
public enum CompositeDealOrder: String, Codable, CaseIterable, Sendable {
    /// Left to right, top to bottom.
    case rowMajor
    /// From the middle outward, so the image grows from the centre.
    case centreOut
    /// In a shuffled order.
    case random

    /// The select's label.
    public var displayName: String {
        switch self {
        case .rowMajor: return "Row by row"
        case .centreOut: return "Centre out"
        case .random: return "Random"
        }
    }
}

/// What a slot with no passing contribution shows on the projector.
public enum CompositeEmptySlots: String, Codable, CaseIterable, Sendable {
    /// The empty grid outline. The default: a reference render is a visible
    /// answer on a projector that the whole class shares.
    case blank
    /// The stored reference render for the slot, dimmed.
    case reference

    /// The select's label.
    public var displayName: String {
        switch self {
        case .blank: return "Blank"
        case .reference: return "Reference render"
        }
    }
}

/// The slots of a composite: a grid for `tile` and `gallery`, a count in
/// order for `sequence` and `sum`.
public enum CompositeLayout: Equatable, Sendable {
    case grid(columns: Int, rows: Int)
    case count(Int)

    /// The same number of slots in the other shape: a grid for a compositor
    /// that takes one, a count otherwise. A count becomes the smallest
    /// near-square grid that holds it, so a compositor change keeps every
    /// slot.
    public func reshaped(forGrid grid: Bool) -> CompositeLayout {
        switch (self, grid) {
        case (.grid, true), (.count, false):
            return self
        case (.grid, false):
            return .count(slotCount)
        case (.count(let count), true):
            var columns = 1
            while columns * columns < count { columns += 1 }
            return .grid(columns: columns, rows: (count + columns - 1) / columns)
        }
    }

    /// The number of slots.
    public var slotCount: Int {
        switch self {
        case .grid(let columns, let rows): return columns * rows
        case .count(let count): return count
        }
    }
}

extension CompositeLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case cols, rows, count
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let count = try c.decodeIfPresent(Int.self, forKey: .count) {
            self = .count(count)
        } else {
            self = .grid(
                columns: try c.decode(Int.self, forKey: .cols), rows: try c.decode(Int.self, forKey: .rows))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .grid(let columns, let rows):
            try c.encode(columns, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .count(let count):
            try c.encode(count, forKey: .count)
        }
    }
}

/// The dimensions and pixel format that every contribution must have. The
/// keys are the footer's (`w`, `h`), the same as `CompositeContribution`.
public struct CompositeContributionShape: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frames: Int
    public let format: CompositePixelFormat

    public init(width: Int, height: Int, frames: Int, format: CompositePixelFormat) {
        self.width = width
        self.height = height
        self.frames = frames
        self.format = format
    }

    /// The decoded byte count of one contribution of this shape.
    public var byteCount: Int { width * height * frames * format.channels }

    private enum CodingKeys: String, CodingKey {
        case width = "w"
        case height = "h"
        case frames, format
    }
}

/// A reason a composite block cannot be saved. Each case's `message` is the
/// text the edit page and MCP show.
public enum CompositeSpecProblem: Equatable, Sendable {
    case layoutDoesNotFitCompositor(CompositeCompositor)
    case slotCountOutOfRange
    case contributionOutOfRange
    case totalPayloadTooLarge
    case frameRateOutOfRange
    case referenceNotForSum

    public var message: String {
        switch self {
        case .layoutDoesNotFitCompositor(let compositor):
            return compositor.usesGrid
                ? "A \(compositor.rawValue) composite needs a layout of columns and rows."
                : "A \(compositor.rawValue) composite needs a layout with a slot count."
        case .slotCountOutOfRange:
            return
                "A composite has 1 to \(CompositeSpec.maxSlots) slots, and a grid has at most "
                + "\(CompositeSpec.maxGridSide) columns and \(CompositeSpec.maxGridSide) rows."
        case .contributionOutOfRange:
            return
                "Each contribution is 1 to \(CompositeSpec.maxContributionSide) pixels wide and high, "
                + "has 1 to \(CompositeSpec.maxFrames) frames, and decodes to at most "
                + "\(CompositeContribution.maxPayloadBytes / 1024) KB."
        case .totalPayloadTooLarge:
            return
                "All the contributions together must decode to at most "
                + "\(CompositeSpec.maxTotalPayloadBytes / (1024 * 1024)) MB. Use fewer slots, "
                + "smaller contributions or fewer frames."
        case .frameRateOutOfRange:
            return "The frame rate is 1 to \(CompositeSpec.maxFrameRate) frames per second."
        case .referenceNotForSum:
            return
                "A sum composite cannot show reference renders in empty slots: a missing angle "
                + "makes the reconstruction blurrier, and that is the lesson."
        }
    }
}

/// The `composite` block of a `classComposite` activity.
public struct CompositeSpec: Codable, Equatable, Sendable {
    public static let maxSlots = 256
    public static let maxGridSide = 32
    public static let maxContributionSide = 256
    public static let maxFrames = 600
    public static let maxFrameRate = 60
    public static let maxTotalPayloadBytes = 4 * 1024 * 1024

    public let compositor: CompositeCompositor
    public let layout: CompositeLayout
    public let contribution: CompositeContributionShape
    public let dealOrder: CompositeDealOrder
    public let frameRate: Int
    /// Show a failed contribution with a mark (the default), or show the slot
    /// as empty.
    public let showFailed: Bool
    public let emptySlots: CompositeEmptySlots

    public init(
        compositor: CompositeCompositor,
        layout: CompositeLayout,
        contribution: CompositeContributionShape,
        dealOrder: CompositeDealOrder = .centreOut,
        frameRate: Int = 12,
        showFailed: Bool = true,
        emptySlots: CompositeEmptySlots = .blank
    ) {
        self.compositor = compositor
        self.layout = layout
        self.contribution = contribution
        self.dealOrder = dealOrder
        self.frameRate = frameRate
        self.showFailed = showFailed
        self.emptySlots = emptySlots
    }

    /// The block a `classComposite` activity gets when its kind is chosen
    /// without one: a 6 × 8 grid of 8 × 8 still RGB tiles. Valid by
    /// construction (`CompositeSpecTests` pins that).
    public static let starter = CompositeSpec(
        compositor: .tile,
        layout: .grid(columns: 8, rows: 6),
        contribution: CompositeContributionShape(width: 8, height: 8, frames: 1, format: .rgb8))

    private enum CodingKeys: String, CodingKey {
        case compositor, layout, contribution, dealOrder, frameRate, showFailed, emptySlots
    }

    /// The three structural fields are required; the display settings decode
    /// with their defaults, as the rest of the activity block does.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            compositor: try c.decode(CompositeCompositor.self, forKey: .compositor),
            layout: try c.decode(CompositeLayout.self, forKey: .layout),
            contribution: try c.decode(CompositeContributionShape.self, forKey: .contribution),
            dealOrder: try c.decodeIfPresent(CompositeDealOrder.self, forKey: .dealOrder) ?? .centreOut,
            frameRate: try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 12,
            showFailed: try c.decodeIfPresent(Bool.self, forKey: .showFailed) ?? true,
            emptySlots: try c.decodeIfPresent(CompositeEmptySlots.self, forKey: .emptySlots) ?? .blank)
    }

    /// The first rule this block breaks, or nil when it can be saved.
    public var problem: CompositeSpecProblem? {
        switch (compositor.usesGrid, layout) {
        case (true, .count), (false, .grid):
            return .layoutDoesNotFitCompositor(compositor)
        case (_, .grid(let columns, let rows)):
            guard (1...Self.maxGridSide).contains(columns), (1...Self.maxGridSide).contains(rows) else {
                return .slotCountOutOfRange
            }
        case (_, .count(let count)):
            guard (1...Self.maxSlots).contains(count) else { return .slotCountOutOfRange }
        }
        guard layout.slotCount <= Self.maxSlots else { return .slotCountOutOfRange }
        guard (1...Self.maxContributionSide).contains(contribution.width),
            (1...Self.maxContributionSide).contains(contribution.height),
            (1...Self.maxFrames).contains(contribution.frames),
            contribution.byteCount <= CompositeContribution.maxPayloadBytes
        else { return .contributionOutOfRange }
        guard layout.slotCount * contribution.byteCount <= Self.maxTotalPayloadBytes else {
            return .totalPayloadTooLarge
        }
        guard (1...Self.maxFrameRate).contains(frameRate) else { return .frameRateOutOfRange }
        if compositor == .sum, emptySlots == .reference { return .referenceNotForSum }
        return nil
    }

    /// True when `other` has the same compositor, layout, contribution shape
    /// and deal order. Those fields lock once a slot is dealt or a student
    /// submits: each student's slot and the size the grader checks depend on
    /// them. The frame rate and the two empty-slot settings are display
    /// settings and stay editable.
    public func hasSameStructure(as other: CompositeSpec) -> Bool {
        compositor == other.compositor && layout == other.layout
            && contribution == other.contribution && dealOrder == other.dealOrder
    }

    /// The same block with new display settings, the structure kept.
    public func withDisplay(frameRate: Int, showFailed: Bool, emptySlots: CompositeEmptySlots) -> CompositeSpec {
        CompositeSpec(
            compositor: compositor, layout: layout, contribution: contribution, dealOrder: dealOrder,
            frameRate: frameRate, showFailed: showFailed, emptySlots: emptySlots)
    }
}
