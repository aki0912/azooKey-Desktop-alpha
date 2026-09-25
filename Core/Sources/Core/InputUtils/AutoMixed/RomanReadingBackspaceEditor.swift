import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Uses the pinned dependency's real roman table; never maintains a second table.
public struct RomanReadingBackspaceEditor: JapaneseBackspaceEditing {
    public init() {}

    public func deletingLastUnit(in raw: String) -> JapaneseBackspaceEdit? {
        guard let parsed = RomanSpanReading.parse(raw), parsed.suffix.isEmpty,
              !parsed.reading.isEmpty else {
            return nil
        }
        var remaining = parsed.reading
        let last = remaining.removeLast()
        // Small vowels and contracted sounds belong to the preceding full-sized kana.
        // A standalone small kana, sokuon, n, or long vowel remains its own unit.
        if "ぁぃぅぇぉゃゅょゎ".contains(last), let previous = remaining.last,
           !"ぁぃぅぇぉゃゅょゎっんー".contains(previous) {
            remaining.removeLast()
        }
        if remaining.isEmpty {
            return .init(raw: "", reading: "")
        }
        // Preserve the longest complete original spelling. Pending n/t cannot be kept
        // by merely truncating: encode the residual kana and verify the entire result.
        for count in stride(from: raw.count - 1, through: 0, by: -1) {
            let prefix = String(raw.prefix(count))
            let prefixReading: String
            if prefix.isEmpty { prefixReading = "" } else {
                guard let part = RomanSpanReading.parse(prefix), part.suffix.isEmpty else { continue }
                prefixReading = part.reading
            }
            guard remaining.hasPrefix(prefixReading),
                  let suffix = Self.encode(String(remaining.dropFirst(prefixReading.count))) else { continue }
            let result = prefix + suffix
            guard let verified = RomanSpanReading.parse(result), verified.suffix.isEmpty,
                  verified.reading == remaining else { continue }
            return .init(raw: result, reading: remaining)
        }
        return nil
    }

    private struct Rule: Sendable { let raw: String; let reading: String }
    private static let rules: [Rule] = {
        guard let table = try? InputStyleManager.exportTable(.defaultRomanToKana) else {
            return []
        }
        return table.split(separator: "\n").compactMap { row in
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2, !columns[0].isEmpty, !columns[1].isEmpty else {
                return nil
            }
            let raw = String(columns[0]), reading = String(columns[1])
            guard let parsed = RomanSpanReading.parse(raw), parsed.suffix.isEmpty,
                  parsed.reading == reading else {
                return nil
            }
            return Rule(raw: raw, reading: reading)
        }
    }()

    private static func encode(_ reading: String) -> String? {
        let characters = Array(reading)
        var best: [String?] = Array(repeating: nil, count: characters.count + 1)
        best[characters.count] = ""
        for index in characters.indices.reversed() {
            let tail = String(characters[index...])
            for rule in rules where tail.hasPrefix(rule.reading) {
                guard let rest = best[index + rule.reading.count] else { continue }
                let candidate = rule.raw + rest
                guard let parsed = RomanSpanReading.parse(candidate), parsed.suffix.isEmpty,
                      parsed.reading == tail else { continue }
                if best[index].map({ candidate.count < $0.count || (candidate.count == $0.count && candidate < $0) }) ?? true {
                    best[index] = candidate
                }
            }
        }
        return best[0]
    }
}
