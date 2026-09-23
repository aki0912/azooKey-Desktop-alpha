/// v1 raw features plus versioned, bounded committed-left-context features.
/// Keys are transient model inputs; they must never be written to runtime logs.
public struct ContextualCharacterFeatures: Sendable, CustomDebugStringConvertible {
    public static let version = "anchored-context-v2"
    public var scalarCount: Int { rawFeatures.scalarCount }
    private let rawFeatures: AnchoredCharacterFeatures
    private let contextKeys: [String]

    public init(_ raw: String, leftContext: CommittedLeftContext = .unavailable) {
        rawFeatures = AnchoredCharacterFeatures(raw)
        contextKeys = Self.makeContextKeys(leftContext)
    }

    public func keys(at index: Int) throws -> [String] {
        try (rawFeatures.keys(at: index) + contextKeys).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    public var debugDescription: String { "ContextualCharacterFeatures(<redacted>)" }

    private static func quoted(_ scalar: Unicode.Scalar) -> String {
        let value = scalar.value
        return "\"\(AnchoredCharacterFeatures.escape((65...90).contains(value) ? value + 32 : value))\""
    }

    private static func shape(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 65...90: "upper"
        case 97...122: "lower"
        case 48...57: "digit"
        case 9...13, 32, 0x3000: "space"
        case 33...47, 58...64, 91...96, 123...126, 0x3001...0x3002, 0xff01, 0xff1f: "punctuation"
        case 0x3041...0x3096, 0x30a1...0x30fa, 0x30fc, 0xff66...0xff9f: "japanese"
        case 0x3400...0x4dbf, 0x4e00...0x9fff, 0xf900...0xfaff, 0x20000...0x323af: "japanese"
        case 0...127: "ascii_other"
        default: "non_ascii"
        }
    }

    private static func makeContextKeys(_ context: CommittedLeftContext) -> [String] {
        guard let text = context.text else { return ["[\"ctx\",\"availability\",\"unavailable\"]"] }
        let scalars = Array(text.unicodeScalars)
        var keys = ["[\"ctx\",\"availability\",\"available\"]"]
        for distance in 1...CommittedLeftContext.scalarLimit {
            let index = scalars.count - distance
            let symbol = index >= 0 ? "[\"CHAR\",\(quoted(scalars[index]))]" : "[\"BOS\"]"
            let category = index >= 0 ? shape(scalars[index]) : "bos"
            keys.append("[\"ctx\",\"char\",\(-distance),\(symbol)]")
            keys.append("[\"ctx\",\"shape\",\(-distance),\"\(category)\"]")
        }
        let boundary = scalars.last.map(shape) ?? "empty"
        keys.append("[\"ctx\",\"boundary\",\"\(boundary)\"]")
        for length in 2...4 where scalars.count >= length {
            let values = scalars.suffix(length).map(quoted).joined(separator: ",")
            keys.append("[\"ctx\",\"suffix\",\(length),[\(values)]]")
        }
        let withoutSpace = scalars.reversed().drop(while: { shape($0) == "space" })
        let word = withoutSpace.prefix(while: { (65...90).contains($0.value) || (97...122).contains($0.value) }).reversed()
        if !word.isEmpty {
            keys.append("[\"ctx\",\"word\",[\(word.map(quoted).joined(separator: ","))]]")
        }
        return keys
    }
}
