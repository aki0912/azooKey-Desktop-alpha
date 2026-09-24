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
        let protection = ProtectedSpanDetector.detect(raw).scalars
        let prior = try baseline.segment(raw)
        let unchangedPrefixCount = zip((previousRaw ?? "").unicodeScalars, raw.unicodeScalars).prefix { $0.0 == $0.1 }.count
        let features = ContextualCharacterFeatures(raw, leftContext: context)
        let scores = try protection.enumerated().map { index, kind in
            kind == .inferred ? try model.score(features, at: index).japaneseProbability : 0.5
        }
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
                if isEnglish(word, range: range, scores: scores, atEnd: end == source.scalarCount,
                             unchangedPrefixCount: unchangedPrefixCount) {
                    result.append(MixedSpan(sourceRange: range, kind: .raw))
                    nextEnglish.append(EnglishRegion(range: range, raw: word))
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
