import Foundation

/// Display-only Japanese punctuation. Original scalars and model inputs stay unchanged.
/// Every replacement is one BMP scalar, preserving the literal run's UTF-16 mapping.
public struct MixedPunctuationPolicy: Sendable {
    private let leftContext: CommittedLeftContext

    public init(leftContext: CommittedLeftContext = .unavailable) {
        self.leftContext = leftContext
    }

    func displaySlices(raw: String, spans: [MixedSpan]) throws -> [UUID: String] {
        let source = TextOffsetMap(raw)
        let scalars = Array(raw.unicodeScalars)
        let context = Array((leftContext.text ?? "").unicodeScalars)
        func protections(_ text: String, offset: Int) -> [Bool] {
            ProtectedSpanDetector.detect(text) { stem in
                // Do not re-protect a bare dotted token already disambiguated as Japanese
                // by the runtime segmenter. Explicit structured tokens still win upstream.
                guard stem.lowerBound >= offset else { return true }
                let lower = stem.lowerBound - offset, upper = stem.upperBound - offset
                let covered = spans.reduce(0) { count, span in
                    guard span.kind == .japaneseRoman || span.kind == .japaneseKana else { return count }
                    return count + max(0, min(upper, span.sourceRange.upperBound) - max(lower, span.sourceRange.lowerBound))
                }
                return covered != stem.count
            }.verbatimScalars
        }
        let localProtected = protections(raw, offset: 0)
        // A committed Japanese sentence must not hide a new filename's structure;
        // conversely a URL continued from committed context must remain protected.
        let protected = context.isEmpty ? localProtected : protections((leftContext.text ?? "") + raw, offset: context.count)
        var english = context.last.map(Self.isLetter) ?? false
        var previous = context.last
        var brackets: [Unicode.Scalar] = []
        var parentheses: [Unicode.Scalar] = []
        for scalar in context {
            if scalar == "[" || scalar == "「" { brackets.append(scalar) }
            if scalar == "]" || scalar == "」", !brackets.isEmpty { brackets.removeLast() }
            if scalar == "(" || scalar == "（" { parentheses.append(scalar) }
            if scalar == ")" || scalar == "）", !parentheses.isEmpty { parentheses.removeLast() }
        }
        var result: [UUID: String] = [:]
        for span in spans {
            var output = String.UnicodeScalarView()
            for index in span.sourceRange.lowerBound..<span.sourceRange.upperBound {
                let scalar = scalars[index]
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                var display = scalar
                if span.kind == .literal, let replacement = Self.japanese(scalar),
                   source.isGraphemeBoundary(index), source.isGraphemeBoundary(index + 1),
                   !protected[context.count + index], !localProtected[index] {
                    // Retain decimals, dates, grouped numbers, negative numbers and indices,
                    // including their incomplete prefixes while the next key is pending.
                    let numeric = previous.map(Self.isDigit) == true || next.map(Self.isDigit) == true
                    if scalar == "]", let opening = brackets.last {
                        display = opening == "「" ? "」" : "]"
                    } else if scalar == ")", let opening = parentheses.last {
                        display = opening == "（" ? "）" : ")"
                    } else if !english && !numeric {
                        display = replacement
                    }
                }
                output.append(display)
                if display == "[" || display == "「" { brackets.append(display) }
                if display == "]" || display == "」", !brackets.isEmpty { brackets.removeLast() }
                if display == "(" || display == "（" { parentheses.append(display) }
                if display == ")" || display == "）", !parentheses.isEmpty { parentheses.removeLast() }
                if Self.isLetter(scalar) {
                    english = span.kind == .raw
                } else if !Self.isASCIIPunctuation(display) {
                    // A space, Japanese character, or digit ends the adjacent English run.
                    english = false
                }
                previous = scalar
            }
            if span.kind == .literal { result[span.id] = String(output) }
        }
        return result
    }

    private static func japanese(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar {
        case "-": return "ー"
        case ".": return "。"
        case ",": return "、"
        case "?": return "？"
        case "!": return "！"
        case "[": return "「"
        case "]": return "」"
        case "(": return "（"
        case ")": return "）"
        default: return nil
        }
    }
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }
    private static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        (33...47).contains(scalar.value) || (58...64).contains(scalar.value)
            || (91...96).contains(scalar.value) || (123...126).contains(scalar.value)
    }
}
