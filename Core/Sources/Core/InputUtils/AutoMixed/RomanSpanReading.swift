import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Conservative adapter over the dependency's standard table; no second roman table.
struct RomanSpanReading {
    let prefix: String
    let suffix: String
    let reading: String

    /// Last independent input-table segment, which can contain several kana (kya, tte, nki).
    /// Check both halves against the full reading; never split an input-table dependency.
    static func splitFinalKana(_ raw: String) -> (prefix: String, tail: String)? {
        guard let parsed = parse(raw), parsed.suffix.isEmpty else { return nil }
        var full = ComposingText()
        full.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        guard let boundary = full.inputIndexToSurfaceIndexMap().keys.filter({ $0 > 0 && $0 < raw.count }).max() else {
            return nil
        }
        let prefix = String(raw.prefix(boundary)), tail = String(raw.dropFirst(boundary))
        guard let left = parse(prefix), left.suffix.isEmpty,
              let right = parse(tail), right.suffix.isEmpty,
              left.reading + right.reading == parsed.reading else { return nil }
        return (prefix, tail)
    }

    static func parse(_ raw: String) -> Self? {
        // Here each input element is exactly one scalar. Never apply this mapping to Unicode raw.
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({
            (97...122).contains($0.value) || $0.value == 39
        }) else { return nil }
        var full = ComposingText()
        full.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        let surface = Array(full.convertTarget)
        let kanaCount = surface.prefix(while: isKana).count
        // An interior untranslated sequence is not a valid Japanese run.
        guard surface.dropFirst(kanaCount).allSatisfy({ character in
            character.unicodeScalars.allSatisfy { (97...122).contains($0.value) || $0.value == 39 }
        }) else { return nil }
        if kanaCount < surface.count {
            // The dependency does not expose its pending-prefix table. Admit only suffixes
            // which its actual composing API can complete with one further roman key.
            // This bounded grammar check is not language inference or a Zenzai request.
            let canComplete = "abcdefghijklmnopqrstuvwxyz'".contains { key in
                var probe = full
                probe.insertAtCursorPosition(String(key), inputStyle: .roman2kana)
                return probe.convertTarget.allSatisfy(isKana)
            }
            guard canComplete else { return nil }
        }
        let boundary = full.inputIndexToSurfaceIndexMap()
            .filter { $0.value <= kanaCount }
            .max { $0.key < $1.key }?.key ?? 0
        let prefix = String(raw.prefix(boundary))
        var complete = ComposingText()
        complete.insertAtCursorPosition(prefix, inputStyle: .roman2kana)
        guard complete.convertTarget.allSatisfy(isKana),
              full.convertTarget.hasPrefix(complete.convertTarget) else { return nil }
        return Self(prefix: prefix, suffix: String(raw.dropFirst(boundary)), reading: complete.convertTarget)
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
    }
}
