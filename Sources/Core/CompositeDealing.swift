// Core/CompositeDealing.swift
//
// How a class composite's slots are dealt and how a dealt slot reaches the
// test script (docs/class-composite.md, slice 3). Pure functions of the
// `CompositeSpec`, so the server's dealer and the tests read one answer.

extension CompositeSpec {

    /// The per-student input names a composite adds. Prefixed, so they cannot
    /// collide with an instructor's own inputs (a `row` or a `slot` is a
    /// likely name for one).
    public static let slotInputName = "composite_slot"
    public static let columnInputName = "composite_col"
    public static let rowInputName = "composite_row"

    /// Every slot, in the order the server deals free ones: one pass of the
    /// sequence is one round, and the second round repeats it.
    ///
    /// `shuffleSeed` decides the `random` order and is ignored by the other
    /// two. The server derives it from the assignment, so one assignment
    /// always deals in one order.
    public func dealSequence(shuffleSeed: UInt64) -> [Int] {
        let slots = Array(0..<layout.slotCount)
        switch dealOrder {
        case .rowMajor:
            return slots
        case .centreOut:
            // Nearest the middle first; a tie goes to the lower slot, so the
            // order is total and the same on every server.
            return slots.sorted { a, b in
                let (da, db) = (distanceFromCentre(a), distanceFromCentre(b))
                return da != db ? da < db : a < b
            }
        case .random:
            var generator = SplitMix64(seed: shuffleSeed)
            var shuffled = slots
            // Fisher–Yates with the seeded generator: deterministic for a seed.
            // (`SplitMix64` is the dataset sampler's generator.)
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let j = Int(generator.next(upperBound: UInt64(i + 1)))
                shuffled.swapAt(i, j)
            }
            return shuffled
        }
    }

    /// The column and row of a slot in a grid layout; nil for a count layout.
    public func gridPosition(ofSlot slot: Int) -> (column: Int, row: Int)? {
        guard case .grid(let columns, _) = layout else { return nil }
        return (slot % columns, slot / columns)
    }

    /// The inputs a test script reads for `slot`: the slot number, and for a
    /// grid its column and row, so a script does not repeat the arithmetic.
    public func inputs(forSlot slot: Int) -> [String: JSONValue] {
        var inputs: [String: JSONValue] = [Self.slotInputName: .int(slot)]
        if let position = gridPosition(ofSlot: slot) {
            inputs[Self.columnInputName] = .int(position.column)
            inputs[Self.rowInputName] = .int(position.row)
        }
        return inputs
    }

    /// The class-coverage item a passing contribution for `slot` records
    /// (slice 4). An unscoped `itemsCovered` class goal counts these.
    public static func coverageItem(forSlot slot: Int) -> String { "slot-\(slot)" }

    /// Every slot's coverage item, in slot order.
    public var coverageItems: [String] { (0..<layout.slotCount).map(Self.coverageItem(forSlot:)) }

    /// Squared distance from the layout's centre, in doubled coordinates so
    /// it stays an integer for an even side (the centre then falls between
    /// two cells).
    private func distanceFromCentre(_ slot: Int) -> Int {
        switch layout {
        case .grid(let columns, let rows):
            let dx = 2 * (slot % columns) - (columns - 1)
            let dy = 2 * (slot / columns) - (rows - 1)
            return dx * dx + dy * dy
        case .count(let count):
            let d = 2 * slot - (count - 1)
            return d * d
        }
    }
}
