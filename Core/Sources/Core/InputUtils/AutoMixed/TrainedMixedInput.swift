import Foundation

/// Explicit opt-in adapter for the playground. T2 safeSpans remains unchanged.
public struct TrainedMixedSegmenter: LanguageSegmenter {
    private let judge: ContextualLanguageSegmenter
    private let model: LogisticLanguageModel
    private let context: CommittedLeftContext
    private let focus: UUID

    public init(model: LogisticLanguageModel, context: CommittedLeftContext = .unavailable, focus: UUID) throws {
        judge = try ContextualLanguageSegmenter(model: model)
        self.model = model
        self.context = context
        self.focus = focus
    }

    public func segment(_ raw: String) throws -> [MixedSpan] {
        let source = TextOffsetMap(raw)
        var proposed = try hypotheses(raw)
        if let last = proposed.last, last.kind == .unresolved {
            if try admitsPendingTail(raw, source: source, span: last) {
                proposed[proposed.count - 1] = MixedSpan(id: last.id, sourceRange: last.sourceRange, kind: .japaneseRoman)
            } else if let split = try kanaTail(raw, source: source, span: last) {
                proposed.removeLast()
                proposed.append(contentsOf: split)
            }
        }
        return try proposed.map { span in
            guard span.kind == .japaneseRoman else { return span }
            if let parsed = RomanSpanReading.parse(try source.slice(span.sourceRange)), !parsed.prefix.isEmpty,
               parsed.suffix.isEmpty || span.sourceRange.upperBound == source.scalarCount {
                return span
            }
            return MixedSpan(id: span.id, sourceRange: span.sourceRange, kind: .unresolved)
        }
    }

    private func hypotheses(_ raw: String) throws -> [MixedSpan] {
        try judge.judge(LanguageJudgmentInput(raw: raw, leftCommittedContext: context,
                                              focusIdentity: focus, revision: 0)).hypotheses
    }

    /// Complete but less certain kana gets a reading-only tail, never a guessed kanji candidate.
    private func kanaTail(_ raw: String, source: TextOffsetMap, span: MixedSpan) throws -> [MixedSpan]? {
        guard let thresholds = model.contextualThresholds,
              span.sourceRange.upperBound == source.scalarCount,
              let split = RomanSpanReading.splitFinalKana(try source.slice(span.sourceRange)) else { return nil }
        let end = span.sourceRange.lowerBound + split.prefix.unicodeScalars.count
        let features = ContextualCharacterFeatures(raw, leftContext: context)
        let scores = try (span.sourceRange.lowerBound..<span.sourceRange.upperBound).map {
            try model.score(features, at: $0).japaneseProbability
        }
        guard scores.allSatisfy({ $0 >= thresholds.minimumJapanese }) else { return nil }
        let prefixScores = scores.prefix(split.prefix.unicodeScalars.count)
        let enter = context.isAvailable ? model.enterJapaneseThreshold : thresholds.enterWithoutContext
        guard prefixScores.reduce(0, +) / Double(prefixScores.count) >= enter else { return nil }
        // Local evidence for showing the tail as kana instead of RAW. This is not a
        // calibrated word probability. Reuse the exported margin without lowering it.
        let margin = scores.suffix(split.tail.unicodeScalars.count).reduce(0.0) { result, p in
            let clipped = min(max(p, 1e-7), 1 - 1e-7)
            return result + log(clipped) - log1p(-clipped)
        }
        guard margin >= thresholds.minimumPathMargin,
              let complete = try hypotheses(source.slice(ScalarRange(0, end))).last,
              complete.kind == .japaneseRoman,
              complete.sourceRange == (try ScalarRange(span.sourceRange.lowerBound, end)) else { return nil }
        return [complete, try MixedSpan(sourceRange: ScalarRange(end, source.scalarCount), kind: .japaneseKana)]
    }

    /// A single bounded prefix check, also valid for pasted raw. No previous display is trusted.
    private func admitsPendingTail(_ raw: String, source: TextOffsetMap, span: MixedSpan) throws -> Bool {
        guard let thresholds = model.contextualThresholds,
              span.sourceRange.upperBound == source.scalarCount,
              let parsed = RomanSpanReading.parse(try source.slice(span.sourceRange)),
              !parsed.prefix.isEmpty, !parsed.suffix.isEmpty else { return false }

        // Check current evidence before removing the unfinished suffix. A previous Japanese
        // prefix must not override new RAW evidence, a hard protection, or low confidence.
        let features = ContextualCharacterFeatures(raw, leftContext: context)
        let floor = max(model.holdJapaneseThreshold, thresholds.minimumJapanese)
        for index in span.sourceRange.lowerBound..<span.sourceRange.upperBound {
            guard try model.score(features, at: index).japaneseProbability >= floor else { return false }
        }

        let end = span.sourceRange.lowerBound + parsed.prefix.unicodeScalars.count
        let completeRaw = try source.slice(ScalarRange(0, end))
        // Retain surrounding raw and the same context. Require the existing entry, minimum,
        // and margin gates to accept exactly this prefix, without expanding another span.
        guard let complete = try hypotheses(completeRaw).last else { return false }
        return complete.kind == .japaneseRoman && complete.sourceRange.lowerBound == span.sourceRange.lowerBound
            && complete.sourceRange.upperBound == end
    }
}

/// Owns only one input session's children; the bridge is shared across input sessions.
@MainActor public final class MixedSessionConverter: JapaneseSpanConverting {
    private let bridge: ZenzaiSpanBridge
    private let sessionID: UUID
    private var compositionID = UUID()
    private var revision: UInt64 = 0
    private var sourceScalarCount = 0
    private let leftContext: String?
    private let rightContext: String?
    private let allowJapaneseReadingFallback: Bool
    public private(set) var lastResults: [UUID: JapaneseSpanResult] = [:]

    public init(bridge: ZenzaiSpanBridge, sessionID: UUID,
                leftContext: String? = nil, rightContext: String? = nil,
                allowJapaneseReadingFallback: Bool = false) {
        self.bridge = bridge
        self.sessionID = sessionID
        self.leftContext = leftContext.map { String($0.suffix(30)) }
        self.rightContext = rightContext.map { String($0.prefix(30)) }
        self.allowJapaneseReadingFallback = allowJapaneseReadingFallback
    }

    public func prepare(revision: UInt64, sourceScalarCount: Int, retaining spanIDs: Set<UUID>) {
        self.revision = revision
        self.sourceScalarCount = sourceScalarCount
        bridge.retain(sessionID: sessionID, compositionID: compositionID, spanIDs: spanIDs)
        lastResults = lastResults.filter { spanIDs.contains($0.key) }
    }

    public func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        try candidates(for: raw, span: span, leftDisplay: "")
    }

    public func candidates(for raw: String, span: MixedSpan, leftDisplay: String) throws -> [MixedCandidate] {
        if span.kind == .japaneseKana {
            // Reading-only tails create no converter child or learnable Candidate token.
            guard span.sourceRange.count == raw.unicodeScalars.count,
                  span.sourceRange.upperBound <= sourceScalarCount,
                  let parsed = RomanSpanReading.parse(raw),
                  parsed.suffix.isEmpty || span.sourceRange.upperBound == sourceScalarCount else { return [] }
            if !allowJapaneseReadingFallback {
                guard span.sourceRange.upperBound == sourceScalarCount, parsed.suffix.isEmpty,
                      !parsed.reading.isEmpty else { return [] }
            }
            return [MixedCandidate(token: UUID().uuidString, text: parsed.reading + parsed.suffix)]
        }
        let left = leftDisplay.isEmpty ? leftContext : (leftContext ?? "") + leftDisplay
        let result = try bridge.candidates(for: JapaneseSpanRequest(
            identity: .init(sessionID: sessionID, compositionID: compositionID, spanID: span.id, revision: revision),
            sourceRange: span.sourceRange, raw: raw, leftContext: left, rightContext: rightContext,
            isAtBufferEnd: span.sourceRange.upperBound == sourceScalarCount
        ))
        lastResults[span.id] = result
        return result.candidates
    }

    public func finishComposition() {
        bridge.release(sessionID: sessionID)
        compositionID = UUID()
        lastResults = [:]
    }
}
