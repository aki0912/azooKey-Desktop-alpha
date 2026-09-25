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
    private var permitsSuffixHypothesis = true
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
        let protectionForDisplay = ProtectedSpanDetector.detect(raw) { stem in
            // A dot plus one pending letter must not turn an entire Japanese sentence
            // into a filename. Re-evaluate current spelling, never trust previous display.
            guard let range = try? ScalarRange(stem.lowerBound, stem.upperBound),
                  let word = try? source.slice(range), lexicon.exactLevel(word) == nil,
                  let reading = RomanSpanReading.parse(word), !reading.prefix.isEmpty, reading.suffix.isEmpty,
                  let prefix = try? source.slice(ScalarRange(0, stem.upperBound)),
                  let independent = try? baseline.evidence(prefix),
                  independent.protection.scalars[stem].allSatisfy({ $0 == .inferred }) else { return true }
            let ps = independent.probabilities[stem]
            if ps.reduce(0, +) / Double(ps.count) >= model.holdJapaneseThreshold { return false }
            guard context.isAvailable else { return true }
            // Context may suppress even the kana preview's spelling evidence. Use the
            // same hold gate on a separate context-free control, not a lower threshold.
            let mean = try? MixedPerformance.measure(.classification) {
                MixedPerformance.count(.scorePass)
                let features = ContextualCharacterFeatures(prefix, leftContext: .unavailable)
                return try stem.reduce(0.0) { try $0 + model.score(features, at: $1).japaneseProbability }
                    / Double(stem.count)
            }
            return mean.map { $0 < model.holdJapaneseThreshold } ?? true
        }
        let evidence = try baseline.evidence(raw, protection: protectionForDisplay)
        let protected = evidence.protection
        let protection = protected.scalars
        let prior = try baseline.segment(raw, evidence: evidence)
        let unchangedPrefixCount = zip((previousRaw ?? "").unicodeScalars, raw.unicodeScalars).prefix { $0.0 == $0.1 }.count
        let scores = evidence.probabilities
        var scoresWithoutContext: [Double]?
        var suffixEvidence: [String: Bool] = [:]
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
                        scoresWithoutContext = try MixedPerformance.measure(.classification) {
                            MixedPerformance.count(.scorePass)
                            let independent = ContextualCharacterFeatures(raw, leftContext: .unavailable)
                            return try protection.enumerated().map { index, kind in
                                kind == .inferred ? try model.score(independent, at: index).japaneseProbability : 0.5
                            }
                        }
                    }
                    english = isEnglish(word, range: range, scores: scoresWithoutContext!,
                                        atEnd: end == source.scalarCount, unchangedPrefixCount: unchangedPrefixCount)
                }
                // An explicit hyphen between complete dictionary words is an English
                // compound, not a Japanese long vowel. The preceding word already
                // passed the English gate; do not reinterpret data/node in isolation.
                if !english, lexicon.exactLevel(word) != nil, result.count >= 2,
                   result[result.count - 2].kind == .raw,
                   lexicon.exactLevel(try source.slice(result[result.count - 2].sourceRange)) != nil,
                   result.last?.kind == .literal,
                   try source.slice(result.last!.sourceRange) == "-" {
                    english = true
                }
                if english {
                    result.append(MixedSpan(sourceRange: range, kind: .raw))
                    nextEnglish.append(EnglishRegion(range: range, raw: word))
                } else if let joined = try longVowelSpan(from: range, source: source, protected: protected) {
                    result.append(joined)
                    end = joined.sourceRange.upperBound
                } else if let split = try embeddedEnglishSplit(in: range, source: source, scores: scores,
                                                               protected: protected, suffixEvidence: &suffixEvidence,
                                                               unchangedPrefixCount: unchangedPrefixCount) {
                    result += split
                    end = split.last!.sourceRange.upperBound
                    for span in split where span.kind == .raw {
                        nextEnglish.append(EnglishRegion(range: span.sourceRange, raw: try source.slice(span.sourceRange)))
                    }
                } else if let whole = japaneseSpan(range, source: source, scores: scores) {
                    // Long committed contexts can suppress otherwise valid Japanese
                    // spelling below the kana-preview gate. Use the existing raw-only
                    // policy as a bounded control; retain context for actual conversion.
                    if whole.kind == .japaneseKana,
                       let restored = try contextIndependentJapanese(in: range, source: source) {
                        result += restored
                        start = end
                        continue
                    }
                    // A language-confidence boundary need not be a conversion boundary.
                    // Rejoin a completed, independently supported tail (kaiha + tu),
                    // while retaining weak reading previews and all English boundaries.
                    if try canRejoinKanaTail(inherited, whole: whole, source: source, scores: scores) {
                        result.append(whole)
                        start = end
                        continue
                    }
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
                        } else if span.kind == .unresolved,
                                  lexicon.exactLevel(text) == nil,
                                  let recovered = try recoverJapaneseRuns(span.sourceRange, source: source, scores: scores) {
                            result += recovered
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

    private func contextIndependentJapanese(in range: ScalarRange, source: TextOffsetMap) throws -> [MixedSpan]? {
        guard context.isAvailable else { return nil }
        let raw = try source.slice(range)
        // Dictionary words and their continuations retain contextual disambiguation.
        // A control that finds any English/RAW/invalid run cannot override that decision.
        guard lexicon.exactLevel(raw) == nil, lexicon.prefixLevel(raw) == nil else { return nil }
        let control = try JapanesePreferredSegmenter(model: model, lexicon: lexicon, policy: policy,
                                                     context: .unavailable, focus: UUID())
        control.permitsSuffixHypothesis = false
        let spans = try control.segment(raw)
        guard spans.contains(where: { $0.kind == .japaneseRoman }),
              spans.allSatisfy({ $0.kind == .japaneseRoman || $0.kind == .japaneseKana }) else { return nil }
        return try spans.map {
            try MixedSpan(sourceRange: ScalarRange(range.lowerBound + $0.sourceRange.lowerBound,
                                                   range.lowerBound + $0.sourceRange.upperBound), kind: $0.kind)
        }
    }

    private func canRejoinKanaTail(_ spans: [MixedSpan], whole: MixedSpan,
                                   source: TextOffsetMap, scores: [Double]) throws -> Bool {
        guard whole.kind == .japaneseRoman, spans.count == 2,
              spans[0].kind == .japaneseRoman, spans[1].kind == .japaneseKana,
              spans[0].sourceRange.lowerBound == whole.sourceRange.lowerBound,
              spans[0].sourceRange.upperBound == spans[1].sourceRange.lowerBound,
              spans[1].sourceRange.upperBound == whole.sourceRange.upperBound else { return false }
        let floor = max(model.holdJapaneseThreshold, model.contextualThresholds?.minimumJapanese ?? 0)
        let tail = spans[1].sourceRange
        guard scores[tail.lowerBound..<tail.upperBound].allSatisfy({ $0 >= floor }),
              let joined = RomanSpanReading.parse(try source.slice(whole.sourceRange)), joined.suffix.isEmpty,
              let prefix = RomanSpanReading.parse(try source.slice(spans[0].sourceRange)), prefix.suffix.isEmpty,
              let suffix = RomanSpanReading.parse(try source.slice(tail)), suffix.suffix.isEmpty,
              !prefix.reading.isEmpty, !suffix.reading.isEmpty else { return false }
        return prefix.reading + suffix.reading == joined.reading
    }

    /// A grammar error must not erase a Japanese-preferred region. Preserve only
    /// independently readable runs; unknown letters keep their exact original range.
    private func recoverJapaneseRuns(_ range: ScalarRange, source: TextOffsetMap,
                                     scores: [Double]) throws -> [MixedSpan]? {
        guard let runs = RomanSpanReading.independentRuns(try source.slice(range),
            isAtBufferEnd: range.upperBound == source.scalarCount) else { return nil }
        var result: [MixedSpan] = []
        for run in runs {
            let part = try ScalarRange(range.lowerBound + run.range.lowerBound, range.lowerBound + run.range.upperBound)
            if run.isJapanese {
                // Recovery is stricter than the ordinary low-confidence kana preview:
                // every readable part must independently meet the exported JA hold gate.
                let probabilities = scores[part.lowerBound..<part.upperBound]
                guard probabilities.reduce(0, +) / Double(probabilities.count) >= model.holdJapaneseThreshold else { return nil }
                guard let japanese = japaneseSpan(part, source: source, scores: scores) else { return nil }
                result.append(japanese)
            } else {
                result.append(MixedSpan(sourceRange: part, kind: .raw))
            }
        }
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

    /// Inspect complete dictionary words independently of the single Viterbi path.
    /// Search is bounded by input length times the lexicon's maximum word length.
    /// Current English evidence and independently valid Japanese flanks remain mandatory.
    private func embeddedEnglishSplit(in block: ScalarRange,
                                      source: TextOffsetMap, scores: [Double],
                                      protected: ProtectedText, suffixEvidence: inout [String: Bool],
                                      unchangedPrefixCount: Int) throws -> [MixedSpan]? {
        let maximum = min(EnglishLexicon.maximumWordLength, block.count)
        guard maximum >= policy.minimumPrefixLength else { return nil }
        // The whole-word decision takes precedence over embedded shorter words.
        // For example, rejecting made as English must not manufacture mad + e.
        let blockRaw = try source.slice(block)
        guard lexicon.exactLevel(blockRaw) == nil else { return nil }
        // Prefix sums reject unsupported candidates/flanks before invoking the roman parser.
        var totals = [0.0], rawCounts = [0]
        for p in scores[block.lowerBound..<block.upperBound] {
            totals.append(totals.last! + p)
            rawCounts.append(rawCounts.last! + (p < 0.5 ? 1 : 0))
        }
        func mean(_ lower: Int, _ upper: Int) -> Double {
            (totals[upper - block.lowerBound] - totals[lower - block.lowerBound]) / Double(upper - lower)
        }
        // Longest match first, earliest start breaks ties; independent of typing history.
        for length in stride(from: maximum, through: policy.minimumPrefixLength, by: -1) {
            for lower in block.lowerBound...(block.upperBound - length) {
                let upper = lower + length
                let fraction = Double(rawCounts[upper - block.lowerBound] - rawCounts[lower - block.lowerBound]) / Double(length)
                guard fraction >= policy.minimumRawFraction,
                      source.isGraphemeBoundary(lower), source.isGraphemeBoundary(upper) else { continue }
                let range = try ScalarRange(lower, upper)
                guard range != block else { continue }
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
                    let originalFlank = try ScalarRange(lower, upper)
                    // Once the English boundary is proposed, validate the remaining
                    // Japanese reading across long vowels, rather than converting de/ta apart.
                    let joined = side == 1 ? try longVowelSpan(from: originalFlank, source: source, protected: protected) : nil
                    let flank = joined?.sourceRange ?? originalFlank
                    let flankRaw = try source.slice(flank)
                    let localMean = joined == nil ? mean(lower, upper)
                        : scores[flank.lowerBound..<flank.upperBound].reduce(0, +) / Double(flank.count)
                    var hasJapaneseEvidence = localMean >= model.holdJapaneseThreshold
                    // Evaluate the suffix using the existing standalone runtime policy,
                    // including its long-vowel grammar. Disable this extra hypothesis in
                    // the control so work cannot recursively branch. Cache only this edit.
                    let anchoredSuffix = side == 1 && permitsSuffixHypothesis
                        && lexicon.prefixLevel(blockRaw) == nil
                        && RomanSpanReading.parse(word)?.suffix.isEmpty != true
                    if !hasJapaneseEvidence, anchoredSuffix,
                       lexicon.exactLevel(flankRaw) == nil, lexicon.prefixLevel(flankRaw) == nil,
                       let parsed = RomanSpanReading.parse(flankRaw), !parsed.reading.isEmpty,
                       parsed.suffix.isEmpty || flank.upperBound == source.scalarCount {
                        if suffixEvidence[flankRaw] == nil {
                            let control = try JapanesePreferredSegmenter(model: model, lexicon: lexicon,
                                policy: policy, context: .unavailable, focus: UUID())
                            control.permitsSuffixHypothesis = false
                            let spans = try control.segment(flankRaw)
                            suffixEvidence[flankRaw] = !spans.isEmpty && spans.allSatisfy { $0.kind == .japaneseRoman }
                        }
                        hasJapaneseEvidence = suffixEvidence[flankRaw] == true
                    }
                    // Keep the dictionary boundary while an otherwise readable tail
                    // remains uncertain. Do not turn dictionary absence into JA evidence,
                    // or leak tail letters into the English anchor (sample+n...).
                    if !hasJapaneseEvidence, anchoredSuffix, flank.upperBound == source.scalarCount,
                       RomanSpanReading.parse(flankRaw) != nil {
                        pieces.append(MixedSpan(sourceRange: flank, kind: .unresolved))
                        continue
                    }
                    // Only a terminal pending-only suffix can be retained without JA evidence.
                    guard hasJapaneseEvidence || (side == 1 && flank.upperBound == source.scalarCount) else {
                        independent = false
                        break
                    }
                    guard let japanese = japaneseSpan(flank, source: source, scores: scores) else {
                        independent = false
                        break
                    }
                    let pendingOnly = flank.upperBound == source.scalarCount && japanese.kind == .japaneseKana
                        && RomanSpanReading.parse(flankRaw)?.reading.isEmpty == true
                    guard pendingOnly || hasJapaneseEvidence else {
                        independent = false
                        break
                    }
                    pieces.append(hasJapaneseEvidence && !pendingOnly
                        ? MixedSpan(sourceRange: flank, kind: .japaneseRoman) : japanese)
                }
                if independent { return pieces }
            }
        }
        return nil
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
