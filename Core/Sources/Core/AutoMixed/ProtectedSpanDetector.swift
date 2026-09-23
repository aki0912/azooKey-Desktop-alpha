import Foundation

public enum ScalarProtection: Sendable, Equatable {
    case inferred, raw, literal, gap
}

public struct ProtectedText: Sendable {
    public let scalars: [ScalarProtection]
    /// Boundary candidates only, not hard RAW masks or decoder resets.
    public let boundaryHints: [Int]
}

public enum ProtectedSpanDetector {
    public static func detect(_ raw: String) -> ProtectedText {
        let scalars = Array(raw.unicodeScalars)
        var policies = initialPolicies(raw, scalars: scalars)
        protectAcronyms(scalars, policies: &policies)
        return ProtectedText(scalars: policies, boundaryHints: boundaryHints(scalars, policies: policies))
    }

    private static func initialPolicies(_ raw: String, scalars: [Unicode.Scalar]) -> [ScalarProtection] {
        var policies = Array(repeating: ScalarProtection.literal, count: scalars.count)
        var offset = 0
        var tokenStart = 0
        for character in raw {
            let length = character.unicodeScalars.count
            let asciiGap = character.unicodeScalars.allSatisfy { $0.value == 32 || (9...13).contains($0.value) }
            if asciiGap {
                policies.replaceSubrange(offset..<(offset + length), with: repeatElement(.gap, count: length))
            } else if length == 1, isLetter(scalars[offset]) {
                policies[offset] = .inferred
            }
            // Whitespace and angle/double quotes are conservative token boundaries.
            // A URL without a separator keeps its entire suffix, even if it resembles JA.
            let delimiter = character.isWhitespace || character == "<" || character == ">" || character == "\""
            if delimiter {
                protectToken(scalars, tokenStart..<offset, policies: &policies)
                tokenStart = offset + length
            }
            offset += length
        }
        protectToken(scalars, tokenStart..<scalars.count, policies: &policies)

        // An internal ASCII apostrophe can belong to roman input (kan'i). The real
        // converter validates that interpretation in T4; no roman table is duplicated here.
        for index in scalars.indices where scalars[index].value == 39 {
            if index > 0, index + 1 < scalars.count,
               policies[index - 1] == .inferred, policies[index + 1] == .inferred,
               isLetter(scalars[index - 1]), isLetter(scalars[index + 1]) {
                policies[index] = .inferred
            }
        }
        return policies
    }

    private static func protectAcronyms(_ scalars: [Unicode.Scalar], policies: inout [ScalarProtection]) {
        var start = 0
        while start < scalars.count {
            if policies[start] != .inferred || !(65...90).contains(scalars[start].value) {
                start += 1
                continue
            }
            var end = start + 1
            while end < scalars.count, policies[end] == .inferred, (65...90).contains(scalars[end].value) {
                end += 1
            }
            if end - start >= 2 {
                for index in start..<end { policies[index] = .raw }
            }
            start = end
        }
    }

    private static func boundaryHints(_ scalars: [Unicode.Scalar], policies: [ScalarProtection]) -> [Int] {
        // A small authored hint, deliberately weaker than URL/acronym protection.
        let hint = Array("Swift".unicodeScalars)
        var boundaries = Set<Int>()
        if scalars.count >= hint.count {
            for start in 0...(scalars.count - hint.count) where scalars[start..<(start + hint.count)].elementsEqual(hint) {
                if policies[start..<(start + hint.count)].allSatisfy({ $0 == .inferred }) {
                    boundaries.formUnion([start, start + hint.count])
                }
            }
        }
        return boundaries.sorted()
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func protectToken(_ scalars: [Unicode.Scalar], _ range: Range<Int>, policies: inout [ScalarProtection]) {
        guard !range.isEmpty else {
            return
        }
        let token = String(String.UnicodeScalarView(scalars[range]))
        let pathOrCode = token.contains("/") || token.contains("\\") || token.contains("_") || token.contains("::")
        let email = token.range(of: #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#, options: .regularExpression) != nil
        let file = token.range(of: #"^[A-Za-z0-9_-]+\.[A-Za-z][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
        let version = token.range(of: #"^[vV]?[0-9]+(?:[.\-][0-9]+)+$"#, options: .regularExpression) != nil
        let web = token.hasPrefix("www.")
        if pathOrCode || email || file || version || web {
            for index in range { policies[index] = .literal }
        }
    }
}
