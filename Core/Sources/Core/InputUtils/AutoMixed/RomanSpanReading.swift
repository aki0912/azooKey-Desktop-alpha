import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Conservative adapter over the dependency's standard table; no second roman table.
struct RomanSpanReading {
    let prefix: String
    let suffix: String
    let reading: String
    let completesTerminalN: Bool
    /// Conversion-only copy; hyphens remain unchanged in the original buffer/ranges.
    var conversionInput: String { Self.conversionInput(prefix) }
    private static func conversionInput(_ raw: String) -> String { raw.replacingOccurrences(of: "-", with: "ー") }

    struct IndependentRun {
        let range: Range<Int>
        let isJapanese: Bool
    }

    /// Split only at boundaries exposed by the real input table, never at guessed
    /// roman syllables. The caller must independently require Japanese evidence.
    static func independentRuns(_ raw: String, isAtBufferEnd: Bool) -> [IndependentRun]? {
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy(isAdmitted) else {
            return nil
        }
        var full = ComposingText()
        full.insertAtCursorPosition(conversionInput(raw), inputStyle: .roman2kana)
        let input = Array(raw), surface = Array(full.convertTarget)
        let boundaries = full.inputIndexToSurfaceIndexMap().sorted { $0.key < $1.key }
        guard boundaries.first?.key == 0, boundaries.first?.value == 0,
              boundaries.last?.key == input.count, boundaries.last?.value == surface.count else {
            return nil
        }
        var runs: [IndependentRun] = []
        for (left, right) in zip(boundaries, boundaries.dropFirst()) {
            guard left.value < right.value else {
                return nil
            }
            let reading = surface[left.value..<right.value]
            let japanese = reading.allSatisfy(isKana)
            let piece = String(input[left.key..<right.key])
            guard matchesIndependentReading(piece, surface: reading, japanese: japanese) else {
                return nil
            }
            if let previous = runs.last, previous.isJapanese == japanese {
                runs[runs.count - 1] = IndependentRun(range: previous.range.lowerBound..<right.key, isJapanese: japanese)
            } else {
                runs.append(IndependentRun(range: left.key..<right.key, isJapanese: japanese))
            }
        }
        // A terminal pending tail can stay attached to its preceding kana run, but
        // an invalid tail such as rn remains exactly rn. No inserted/deleted keys.
        if isAtBufferEnd, runs.count >= 2, let tail = runs.last, !tail.isJapanese {
            let preceding = runs[runs.count - 2]
            let range = preceding.range.lowerBound..<tail.range.upperBound
            if let parsed = parse(String(input[range])), !parsed.reading.isEmpty {
                runs.removeLast(2)
                runs.append(IndependentRun(range: range, isJapanese: true))
            }
        }
        guard runs.first?.isJapanese == true, runs.contains(where: { !$0.isJapanese }) else {
            return nil
        }
        return runs
    }

    private static func matchesIndependentReading(_ piece: String, surface: ArraySlice<Character>, japanese: Bool) -> Bool {
        if japanese {
            guard let parsed = parse(piece), parsed.suffix.isEmpty else {
                return false
            }
            return parsed.reading == String(surface)
        }
        // A mixed independent segment cannot safely be divided further.
        return surface.allSatisfy({ !isKana($0) }) && piece == String(surface)
    }

    /// Last independent input-table segment, which can contain several kana (kya, tte, nki).
    /// Check both halves against the full reading; never split an input-table dependency.
    static func splitFinalKana(_ raw: String) -> (prefix: String, tail: String)? {
        guard let parsed = parse(raw), parsed.suffix.isEmpty else {
            return nil
        }
        var full = ComposingText()
        full.insertAtCursorPosition(conversionInput(raw), inputStyle: .roman2kana)
        guard let boundary = full.inputIndexToSurfaceIndexMap().keys.filter({ $0 > 0 && $0 < raw.count }).max() else {
            return nil
        }
        let prefix = String(raw.prefix(boundary)), tail = String(raw.dropFirst(boundary))
        guard let left = parse(prefix), left.suffix.isEmpty,
              let right = parse(tail), right.suffix.isEmpty,
              left.reading + right.reading == parsed.reading else {
            return nil
        }
        return (prefix, tail)
    }

    static func parse(_ raw: String) -> Self? {
        MixedPerformance.measure(.roman) { parseUnmeasured(raw) }
    }

    private static func parseUnmeasured(_ raw: String) -> Self? {
        // The admitted characters are each one scalar/grapheme. Hyphen normalization
        // changes neither count; arbitrary Unicode input must not use this mapping.
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy(isAdmitted) else {
            return nil
        }
        var full = ComposingText()
        full.insertAtCursorPosition(conversionInput(raw), inputStyle: .roman2kana)
        // A Japanese long-vowel word can preview its terminal n as ん. Use the
        // dependency's end-of-composition rule; rebuild from raw on every next key.
        // Ordinary pending roman tails (asitan, etc.) retain their existing behavior.
        if raw.contains("-") || raw.contains("ー"), raw.hasSuffix("n"), full.convertTarget.hasSuffix("n") {
            var completed = full
            completed.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
            if completed.convertTarget.allSatisfy(isKana) {
                return Self(prefix: raw, suffix: "", reading: completed.convertTarget, completesTerminalN: true)
            }
        }
        let surface = Array(full.convertTarget)
        let kanaCount = surface.prefix(while: isKana).count
        // An interior untranslated sequence is not a valid Japanese run.
        guard surface.dropFirst(kanaCount).allSatisfy({ character in
            character.unicodeScalars.allSatisfy { (97...122).contains($0.value) || $0.value == 39 }
        }) else {
            return nil
        }
        if kanaCount < surface.count {
            // The dependency does not expose its pending-prefix table. Admit only suffixes
            // which its actual composing API can complete with one further roman key.
            // This bounded grammar check is not language inference or a Zenzai request.
            let canComplete = "abcdefghijklmnopqrstuvwxyz'".contains { key in
                var probe = full
                probe.insertAtCursorPosition(String(key), inputStyle: .roman2kana)
                return probe.convertTarget.allSatisfy(isKana)
            }
            guard canComplete else {
                return nil
            }
        }
        let boundary = full.inputIndexToSurfaceIndexMap()
            .filter { $0.value <= kanaCount }
            .max { $0.key < $1.key }?.key ?? 0
        let prefix = String(raw.prefix(boundary))
        var complete = ComposingText()
        complete.insertAtCursorPosition(conversionInput(prefix), inputStyle: .roman2kana)
        guard complete.convertTarget.allSatisfy(isKana),
              full.convertTarget.hasPrefix(complete.convertTarget) else {
            return nil
        }
        return Self(prefix: prefix, suffix: String(raw.dropFirst(boundary)), reading: complete.convertTarget, completesTerminalN: false)
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC }
    }

    private static func isAdmitted(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value) || scalar.value == 39 || scalar.value == 45 || scalar.value == 0x30FC
    }
}
