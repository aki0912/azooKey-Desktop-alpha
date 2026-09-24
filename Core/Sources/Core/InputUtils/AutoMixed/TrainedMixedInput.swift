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
        if let last = proposed.last, last.kind == .unresolved,
           try admitsPendingTail(raw, source: source, span: last) {
            proposed[proposed.count - 1] = MixedSpan(id: last.id, sourceRange: last.sourceRange, kind: .japaneseRoman)
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
    public private(set) var lastResults: [UUID: JapaneseSpanResult] = [:]

    public init(bridge: ZenzaiSpanBridge, sessionID: UUID,
                leftContext: String? = nil, rightContext: String? = nil) {
        self.bridge = bridge
        self.sessionID = sessionID
        self.leftContext = leftContext.map { String($0.suffix(30)) }
        self.rightContext = rightContext.map { String($0.prefix(30)) }
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
