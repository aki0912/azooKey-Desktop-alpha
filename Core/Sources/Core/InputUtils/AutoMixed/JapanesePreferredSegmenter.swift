import Foundation

/// Trial display policy around the frozen statistical judge. One instance per composition
/// owner, called synchronously by MixedCompositionEngine; history stays in memory only.
public final class JapanesePreferredSegmenter: LanguageSegmenter {
    private struct EnglishRegion {
        let range: ScalarRange
        let raw: String
    }
    private let baseline: TrainedMixedSegmenter
    private let model: LogisticLanguageModel
    private let context: CommittedLeftContext
    private let lexicon: EnglishLexicon
    private let policy: EnglishDecisionPolicy
    private var previousEnglish: [EnglishRegion] = []
    private var previousRaw: String?
    var retainedEnglishRegionCount: Int { previousEnglish.count }

    public init(model: LogisticLanguageModel, lexicon: EnglishLexicon, policy: EnglishDecisionPolicy,
                context: CommittedLeftContext = .unavailable, focus: UUID) throws {
        self.model = model
        self.context = context
        self.lexicon = lexicon
        self.policy = policy
        baseline = try TrainedMixedSegmenter(model: model, context: context, focus: focus)
    }

    public func reset() { previousEnglish = []; previousRaw = nil }

    public func segment(_ raw: String) throws -> [MixedSpan] {
        let source = TextOffsetMap(raw)
        guard source.scalarCount <= 4096 else { reset(); throw AutoMixedError.invalidRange }
        let protected = ProtectedSpanDetector.detect(raw)
        let protection = protected.scalars
        let prior = try baseline.segment(raw)
        let unchangedPrefixCount = zip((previousRaw ?? "").unicodeScalars, raw.unicodeScalars).prefix { $0.0 == $0.1 }.count
        let features = ContextualCharacterFeatures(raw, leftContext: context)
        let scores = try protection.enumerated().map { index, kind in
            kind == .inferred ? try model.score(features, at: index).japaneseProbability : 0.5
        }
        var scoresWithoutContext: [Double]?
        var nextEnglish: [EnglishRegion] = []
        var result: [MixedSpan] = []
        var start = 0
        while start < source.scalarCount {
            var end = start + 1
            while end < source.scalarCount, protection[end] == protection[start] { end += 1 }
            let range = try ScalarRange(start, end)
            if protection[start] != .inferred {
                let kind: SpanKind = protection[start] == .raw ? .raw : (protection[start] == .gap ? .gap : .literal)
                result.append(MixedSpan(sourceRange: range, kind: kind))
            } else {
                let word = try source.slice(range)
                let inherited = try prior.compactMap { span -> MixedSpan? in
                    let lower = max(start, span.sourceRange.lowerBound), upper = min(end, span.sourceRange.upperBound)
                    guard lower < upper else { return nil }
                    return try MixedSpan(sourceRange: ScalarRange(lower, upper), kind: span.kind)
                }
                var english = isEnglish(word, range: range, scores: scores, atEnd: end == source.scalarCount,
                                        unchangedPrefixCount: unchangedPrefixCount)
                // A committed Japanese context can overwhelm the current spelling. For a
                // whole dictionary word (or permitted terminal prefix) that cannot yet form
                // complete Japanese, require the same English gates on current raw evidence.
                // Complete roman words such as made/name/note still use contextual judgment.
                if !english, context.isAvailable, word.utf8.count >= policy.minimumPrefixLength,
                   lexicon.exactLevel(word) != nil || (end == source.scalarCount && lexicon.prefixLevel(word) != nil),
                   RomanSpanReading.parse(word)?.suffix.isEmpty != true {
                    if scoresWithoutContext == nil {
                        let independent = ContextualCharacterFeatures(raw, leftContext: .unavailable)
                        scoresWithoutContext = try protection.enumerated().map { index, kind in
                            kind == .inferred ? try model.score(independent, at: index).japaneseProbability : 0.5
                        }
                    }
                    english = isEnglish(word, range: range, scores: scoresWithoutContext!,
                                        atEnd: end == source.scalarCount, unchangedPrefixCount: unchangedPrefixCount)
                }
                if english {
                    result.append(MixedSpan(sourceRange: range, kind: .raw))
                    nextEnglish.append(EnglishRegion(range: range, raw: word))
                } else if let joined = try longVowelSpan(from: range, source: source, protected: protected) {
                    result.append(joined)
                    end = joined.sourceRange.upperBound
                } else if let split = try embeddedEnglishSplit(inherited, in: range, source: source, scores: scores,
                                                               unchangedPrefixCount: unchangedPrefixCount) {
                    result += split
                    for span in split where span.kind == .raw {
                        nextEnglish.append(EnglishRegion(range: span.sourceRange, raw: try source.slice(span.sourceRange)))
                    }
                } else if let whole = japaneseSpan(range, source: source, scores: scores) {
                    // Preserve already accepted kanji/reading boundaries such as asitano + te.
                    // Never scan arbitrary substrings for dictionary matches inside a valid roman run.
                    let anchors = inherited.filter { $0.kind == .japaneseRoman || $0.kind == .japaneseKana }
                    var pieces: [MixedSpan] = []
                    var cursor = start
                    var independent = true
                    for anchor in anchors {
                        if cursor < anchor.sourceRange.lowerBound {
                            let gap = try ScalarRange(cursor, anchor.sourceRange.lowerBound)
                            if let japanese = japaneseSpan(gap, source: source, scores: scores) { pieces.append(japanese) }
                            else { independent = false; break }
                        }
                        pieces.append(anchor)
                        cursor = anchor.sourceRange.upperBound
                    }
                    if independent, cursor < end {
                        if let japanese = japaneseSpan(try ScalarRange(cursor, end), source: source, scores: scores) {
                            pieces.append(japanese)
                        } else { independent = false }
                    }
                    result += independent ? pieces : [whole]
                } else {
                    // Invalid whole-token roman input may still contain a model-proposed English
                    // region followed by Japanese (meeting + desu). Use only existing boundaries.
                    for span in inherited {
                        let text = try source.slice(span.sourceRange)
                        if span.kind == .raw || span.kind == .unresolved,
                           isEnglish(text, range: span.sourceRange, scores: scores,
                                     atEnd: span.sourceRange.upperBound == source.scalarCount,
                                     unchangedPrefixCount: unchangedPrefixCount) {
                            result.append(MixedSpan(id: span.id, sourceRange: span.sourceRange, kind: .raw))
                            nextEnglish.append(EnglishRegion(range: span.sourceRange, raw: text))
                        } else if span.kind == .unresolved,
                                  let japanese = japaneseSpan(span.sourceRange, source: source, scores: scores) {
                            result.append(japanese)
                        } else {
                            result.append(span)
                        }
                    }
                }
            }
            start = end
        }
        try MixedMarkedTextRenderer.validate(spans: result, source: source)
        previousEnglish = nextEnglish
        previousRaw = raw.isEmpty ? nil : raw
        return result
    }

    /// Join Japanese roman runs through long vowels before requesting candidates.
    /// A recognized English prefix keeps its hyphen. Once the prefix is Japanese,
    /// validate the whole spelling: fragments such as pa/men inside su-pa-/ra-men
    /// must not be judged as independent English words. Protection inputs stay original.
    private func longVowelSpan(from first: ScalarRange, source: TextOffsetMap, protected: ProtectedText) throws -> MixedSpan? {
        let scalars = Array(source.text.unicodeScalars)
        guard let initial = RomanSpanReading.parse(try source.slice(first)),
              !initial.reading.isEmpty, initial.suffix.isEmpty else { return nil }
        var end = first.upperBound
        var hasLongVowel = false
        while end < scalars.count, !protected.verbatimScalars[end],
              source.isGraphemeBoundary(end), source.isGraphemeBoundary(end + 1),
              scalars[end] == "-" || scalars[end] == "ー" {
            if end + 1 < scalars.count, (48...57).contains(scalars[end + 1].value) { break }
            hasLongVowel = true
            end += 1
            while end < scalars.count, protected.scalars[end] == .inferred { end += 1 }
        }
        guard hasLongVowel else { return nil }
        let range = try ScalarRange(first.lowerBound, end)
        guard let parsed = RomanSpanReading.parse(try source.slice(range)),
              parsed.suffix.isEmpty || end == scalars.count else { return nil }
        return MixedSpan(sourceRange: range, kind: .japaneseRoman)
    }

    /// Recover one complete English word using only model-proposed RAW boundaries.
    /// A word may bridge several runs (a weak JA letter inside meeting), but its
    /// Japanese flanks must independently parse and retain the model's hold evidence.
    /// A pending-only buffer tail stays verbatim, so it needs no Japanese promotion.
    private func embeddedEnglishSplit(_ inherited: [MixedSpan], in block: ScalarRange,
                                      source: TextOffsetMap, scores: [Double],
                                      unchangedPrefixCount: Int) throws -> [MixedSpan]? {
        var best: [MixedSpan]?
        var bestLength = 0
        for (index, first) in inherited.enumerated() where first.kind == .raw {
            for last in inherited[index...] {
                let range = try ScalarRange(first.sourceRange.lowerBound, last.sourceRange.upperBound)
                if range.count > 32 { break } // Same maximum word length as the lexicon.
                guard last.kind == .raw, range != block,
                      range.count >= policy.minimumPrefixLength, range.count > bestLength else { continue }
                let word = try source.slice(range)
                guard lexicon.exactLevel(word) != nil,
                      isEnglish(word, range: range, scores: scores, atEnd: false,
                                unchangedPrefixCount: unchangedPrefixCount) else { continue }
                var pieces: [MixedSpan] = []
                var independent = true
                let flanks = [(block.lowerBound, range.lowerBound), (range.upperBound, block.upperBound)]
                for (side, (lower, upper)) in flanks.enumerated() {
                    if side == 1 { pieces.append(MixedSpan(sourceRange: range, kind: .raw)) }
                    guard lower < upper else { continue }
                    let flank = try ScalarRange(lower, upper)
                    let ps = scores[lower..<upper]
                    guard let japanese = japaneseSpan(flank, source: source, scores: scores) else {
                        independent = false
                        break
                    }
                    let flankRaw = try source.slice(flank)
                    let pendingOnly = upper == source.scalarCount && japanese.kind == .japaneseKana
                        && RomanSpanReading.parse(flankRaw)?.reading.isEmpty == true
                    guard pendingOnly || ps.reduce(0, +) / Double(ps.count) >= model.holdJapaneseThreshold else {
                        independent = false
                        break
                    }
                    pieces.append(japanese)
                }
                if independent { best = pieces; bestLength = range.count }
            }
        }
        return best
    }

    private func japaneseSpan(_ range: ScalarRange, source: TextOffsetMap, scores: [Double]) -> MixedSpan? {
        guard let text = try? source.slice(range), let parsed = RomanSpanReading.parse(text),
              parsed.suffix.isEmpty || range.upperBound == source.scalarCount else { return nil }
        let ps = scores[range.lowerBound..<range.upperBound]
        let mean = ps.reduce(0, +) / Double(ps.count)
        // Language defaults to Japanese; confidence now chooses kanji versus a reading preview.
        let kind: SpanKind = !parsed.prefix.isEmpty && mean >= model.holdJapaneseThreshold ? .japaneseRoman : .japaneseKana
        return MixedSpan(sourceRange: range, kind: kind)
    }

    private func isEnglish(_ raw: String, range: ScalarRange, scores: [Double], atEnd: Bool,
                           unchangedPrefixCount: Int) -> Bool {
        let ps = scores[range.lowerBound..<range.upperBound]
        let mean = ps.reduce(0, +) / Double(ps.count)
        let rawFraction = Double(ps.filter { $0 < 0.5 }.count) / Double(ps.count)
        guard rawFraction >= policy.minimumRawFraction else { return false }
        let continuing = previousEnglish.contains {
            $0.range.lowerBound == range.lowerBound && unchangedPrefixCount >= range.lowerBound
                && (raw.hasPrefix($0.raw) || $0.raw.hasPrefix(raw))
        }
        if let level = lexicon.exactLevel(raw) {
            var limit = level <= 20 ? policy.commonEntryMaximumJapaneseMean : policy.otherEntryMaximumJapaneseMean
            if raw.utf8.count < policy.minimumPrefixLength { limit = min(limit, policy.shortWordMaximumJapaneseMean) }
            if continuing { limit += policy.holdMeanAllowance }
            if mean <= limit { return true }
        }
        if atEnd, raw.utf8.count >= policy.minimumPrefixLength,
           let level = lexicon.prefixLevel(raw), level <= 20 {
            let limit = policy.prefixMaximumJapaneseMean + (continuing ? policy.holdMeanAllowance : 0)
            return mean <= limit
        }
        return false
    }
}
