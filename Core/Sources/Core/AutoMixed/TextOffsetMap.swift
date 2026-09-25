/// Owns the string whose indices it exposes. Rebuild after every edit.
public struct TextOffsetMap: Sendable {
    public let text: String
    public let graphemeBoundaries: [Int]
    private let scalarIndices: [String.Index]
    private let utf16Offsets: [Int]
    public var scalarCount: Int { scalarIndices.count - 1 }
    public var utf16Count: Int { utf16Offsets.last ?? 0 }

    public init(_ text: String) {
        self.text = text
        self.scalarIndices = Array(text.unicodeScalars.indices) + [text.endIndex]
        var offsets = [0]
        for scalar in text.unicodeScalars {
            offsets.append(offsets[offsets.count - 1] + scalar.utf16.count)
        }
        self.utf16Offsets = offsets
        var boundaries = [0]
        for character in text {
            boundaries.append(boundaries[boundaries.count - 1] + character.unicodeScalars.count)
        }
        self.graphemeBoundaries = boundaries
    }

    public func index(atScalar offset: Int) throws -> String.Index {
        guard scalarIndices.indices.contains(offset) else {
            throw AutoMixedError.invalidRange
        }
        return scalarIndices[offset]
    }

    public func scalarOffset(at index: String.Index) -> Int? {
        scalarIndices.firstIndex(of: index)
    }

    public func utf16Offset(atScalar offset: Int) throws -> Int {
        guard utf16Offsets.indices.contains(offset) else {
            throw AutoMixedError.invalidRange
        }
        return utf16Offsets[offset]
    }

    /// A position inside a surrogate pair has no scalar boundary.
    public func scalarOffset(atUTF16 offset: Int) -> Int? {
        utf16Offsets.firstIndex(of: offset)
    }

    public func slice(_ range: ScalarRange) throws -> String {
        let lower = try index(atScalar: range.lowerBound)
        let upper = try index(atScalar: range.upperBound)
        return String(text.unicodeScalars[lower..<upper])
    }

    public func isGraphemeBoundary(_ offset: Int) -> Bool {
        graphemeBoundaries.contains(offset)
    }
}
