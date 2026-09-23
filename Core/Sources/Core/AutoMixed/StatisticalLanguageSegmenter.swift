/// T2 inference without roman validation, stability policy, learning, or application wiring.
public struct StatisticalLanguageSegmenter: LanguageSegmenter, Sendable {
    private let model: LogisticLanguageModel

    public init(model: LogisticLanguageModel) {
        self.model = model
    }

    /// JA labels remain hypotheses until the standard input table can validate them in T4.
    /// The T1 engine therefore preserves their source text instead of requesting conversion.
    public func segment(_ raw: String) throws -> [MixedSpan] {
        try hypotheses(raw).map { span in
            MixedSpan(id: span.id, sourceRange: span.sourceRange,
                      kind: span.kind == .japaneseRoman ? .unresolved : span.kind)
        }
    }

    public func hypotheses(_ raw: String) throws -> [MixedSpan] {
        let features = AnchoredCharacterFeatures(raw)
        let protection = ProtectedSpanDetector.detect(raw)
        let probabilities = try protection.scalars.enumerated().map { index, policy in
            policy == .inferred ? try model.score(features, at: index).japaneseProbability : 0.5
        }
        let labels = try ViterbiLanguageDecoder.decodeBlocks(
            probabilities, protections: protection.scalars, switchPenalty: model.switchPenalty
        )
        var spans: [MixedSpan] = []
        var start = 0
        while start < labels.count {
            var end = start + 1
            while end < labels.count, labels[end] == labels[start] { end += 1 }
            spans.append(try MixedSpan(sourceRange: ScalarRange(start, end), kind: labels[start]))
            start = end
        }
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
        return spans
    }
}
