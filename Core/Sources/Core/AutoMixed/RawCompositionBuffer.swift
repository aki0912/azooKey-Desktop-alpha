/// The sole source of input text. Displayed candidates never mutate this buffer.
public struct RawCompositionBuffer: Sendable {
    public var text: String { offsets.text }
    public private(set) var cursorScalarOffset: Int
    public private(set) var offsets: TextOffsetMap
    public var isEmpty: Bool { text.isEmpty }

    public init(_ text: String = "") {
        self.offsets = TextOffsetMap(text)
        self.cursorScalarOffset = text.unicodeScalars.count
    }

    public mutating func moveCursor(toScalar offset: Int) throws {
        _ = try offsets.index(atScalar: offset)
        guard offsets.isGraphemeBoundary(offset) else {
            throw AutoMixedError.notGraphemeBoundary
        }
        cursorScalarOffset = offset
    }

    public mutating func replace(_ range: ScalarRange, with replacement: String) throws {
        let map = offsets
        let lower = try map.index(atScalar: range.lowerBound)
        let upper = try map.index(atScalar: range.upperBound)
        guard map.isGraphemeBoundary(range.lowerBound), map.isGraphemeBoundary(range.upperBound) else {
            throw AutoMixedError.notGraphemeBoundary
        }
        var updated = text
        updated.unicodeScalars.replaceSubrange(lower..<upper, with: replacement.unicodeScalars)
        // One immutable map per edit; readers and copied buffers share its value safely.
        offsets = TextOffsetMap(updated)
        let insertedEnd = range.lowerBound + replacement.unicodeScalars.count
        // An inserted combining mark/ZWJ can join its neighbours. Never leave the caret
        // inside the new grapheme, including after deleting text between two graphemes.
        cursorScalarOffset = offsets.graphemeBoundaries.first(where: { $0 >= insertedEnd }) ?? offsets.scalarCount
    }

    public mutating func insert(_ text: String) throws {
        try replace(ScalarRange(cursorScalarOffset, cursorScalarOffset), with: text)
    }

    @discardableResult
    public mutating func deleteBackward() throws -> Bool {
        guard let previous = offsets.graphemeBoundaries.last(where: { $0 < cursorScalarOffset }) else {
            return false
        }
        try replace(ScalarRange(previous, cursorScalarOffset), with: "")
        return true
    }
}
