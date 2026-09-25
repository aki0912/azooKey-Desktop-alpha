/// Scalar-based feature-spec v1. Canonical keys match Python's ensure_ascii JSON writer.
public struct AnchoredCharacterFeatures: Sendable {
    public static let version = "anchored-char-v1"
    public let scalarCount: Int
    private let symbols: [String]
    private let shapes: [String]

    public init(_ raw: String) {
        let scalars = Array(raw.unicodeScalars)
        scalarCount = scalars.count
        symbols = scalars.map { scalar in
            let value = scalar.value
            let folded = (65...90).contains(value) ? value + 32 : value
            return "[\"CHAR\",\"\(Self.escape(folded))\"]"
        }
        shapes = scalars.map { scalar in
            switch scalar.value {
            case 65...90: "upper"
            case 97...122: "lower"
            case 48...57: "digit"
            case 0...127: "ascii_other"
            default: "non_ascii"
            }
        }
    }

    public func keys(at index: Int) throws -> [String] {
        try unsortedKeys(at: index).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Scoring sorts the model indices before summation; sorting these strings too
    /// is redundant. Family/offset/length identify every key uniquely.
    func unsortedKeys(at index: Int) throws -> [String] {
        guard (0..<scalarCount).contains(index) else {
            throw AutoMixedError.invalidRange
        }
        var keys: [String] = []
        keys.reserveCapacity(61)
        for offset in -8...8 {
            keys.append("[\"char\",\(offset),\(symbol(at: index + offset))]")
            keys.append("[\"shape\",\(offset),\"\(shape(at: index + offset))\"]")
        }
        for length in 2...4 {
            for start in -4...4 {
                let window = (0..<length).map { symbol(at: index + start + $0) }.joined(separator: ",")
                keys.append("[\"ngram\",\(length),\(start),[\(window)]]")
            }
        }
        return keys
    }

    private func symbol(at position: Int) -> String {
        if position < 0 {
            return "[\"BOS\"]"
        }
        if position >= scalarCount {
            return "[\"EOS\"]"
        }
        return symbols[position]
    }

    private func shape(at position: Int) -> String {
        if position < 0 {
            return "bos"
        }
        if position >= scalarCount {
            return "eos"
        }
        return shapes[position]
    }

    static func escape(_ value: UInt32) -> String {
        switch value {
        case 0x22: return "\\\""
        case 0x5c: return "\\\\"
        case 8: return "\\b"
        case 9: return "\\t"
        case 10: return "\\n"
        case 12: return "\\f"
        case 13: return "\\r"
        case 0x20...0x7e: return String(Unicode.Scalar(value)!)
        case 0...0xffff: return escapeCodeUnit(value)
        default:
            let supplementary = value - 0x10000
            return escapeCodeUnit(0xd800 + (supplementary >> 10)) + escapeCodeUnit(0xdc00 + (supplementary & 0x3ff))
        }
    }

    private static func escapeCodeUnit(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
    }
}
