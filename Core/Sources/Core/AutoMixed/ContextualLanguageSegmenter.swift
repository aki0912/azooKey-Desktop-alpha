import Foundation

/// Stateless T3 candidate: never reads an app, caches context, or calls a converter.
public struct ContextualLanguageSegmenter: ContextualLanguageJudging, Sendable {
    private let model: LogisticLanguageModel
    private let thresholds: ContextualDecisionThresholds

    public init(model: LogisticLanguageModel) throws {
        guard model.featureSpecVersion == ContextualCharacterFeatures.version,
              let thresholds = model.contextualThresholds else { throw LanguageModelError.unsupportedVersion }
        self.model = model
        self.thresholds = thresholds
    }

    public func judge(_ input: LanguageJudgmentInput) throws -> LanguageJudgment {
        let features = ContextualCharacterFeatures(input.raw, leftContext: input.leftCommittedContext)
        let protection = ProtectedSpanDetector.detect(input.raw)
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
            var kind = labels[start]
            if kind == .japaneseRoman {
                let ps = probabilities[start..<end]
                let mean = ps.reduce(0, +) / Double(ps.count)
                // Cost of replacing this entire JA run with RAW while fixing all other labels,
                // minus the selected path cost. This is NOT a calibrated probability/runner-up path.
                var margin = ps.reduce(0) { result, p in
                    let clipped = min(max(p, 1e-7), 1 - 1e-7)
                    return result + log(clipped) - log1p(-clipped)
                }
                if start > 0, labels[start - 1] == .raw { margin -= model.switchPenalty }
                if end < labels.count, labels[end] == .raw { margin -= model.switchPenalty }
                let enter = input.leftCommittedContext.isAvailable
                    ? model.enterJapaneseThreshold : thresholds.enterWithoutContext
                if mean < enter || ps.min()! < thresholds.minimumJapanese || margin < thresholds.minimumPathMargin {
                    kind = .unresolved
                }
            }
            spans.append(try MixedSpan(sourceRange: ScalarRange(start, end), kind: kind))
            start = end
        }
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(input.raw))
        return LanguageJudgment(requestID: input.requestID, hypotheses: spans)
    }
}
