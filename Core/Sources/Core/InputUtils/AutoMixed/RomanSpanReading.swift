import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Conservative adapter over the dependency's standard table; no second roman table.
struct RomanSpanReading {
    let prefix: String
    let suffix: String
    let reading: String

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
