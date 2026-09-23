@testable import Core
import Foundation
import Testing

private let contextFixtureRoot = "Tools/AutoMixedTraining/fixtures/"

private func contextModelData(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    let data = try Data(contentsOf: autoMixedRepositoryFile(contextFixtureRoot + "language_model_v2_fixture.json"))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    mutate(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func fixedModel(probability: Double, missing: Double = 0.97, minimum: Double = 0.55,
                        margin: Double = 1.2) throws -> LogisticLanguageModel {
    try LogisticLanguageModel(testFixture: contextModelData {
        $0["vocabulary"] = [String]()
        $0["coefficients"] = [Double]()
        $0["intercept"] = log(probability / (1 - probability))
        $0["calibration"] = ["a": 1, "c": 0]
        $0["thresholds"] = ["enter_ja": 0.90, "hold_ja": 0.65, "enter_ja_without_context": missing,
                            "minimum_ja": minimum, "minimum_path_margin": margin]
    })
}

private func input(_ raw: String, _ context: CommittedLeftContext = .unavailable) -> LanguageJudgmentInput {
    LanguageJudgmentInput(raw: raw, leftCommittedContext: context, focusIdentity: UUID(), revision: 1)
}

private struct ContextGolden: Decodable {
    let feature_spec_version: String
    let kind: String
    let vectors: [Vector]
    struct Vector: Decodable {
        let raw: String
        let index: Int
        let left_context: String?
        let features: [String]
        let active_indices: [Int]
        let logit: Double
        let p_ja: Double
    }
}

private func checkContextGolden(_ file: URL, count: Int? = nil) throws {
    let reference = try JSONDecoder().decode(ContextGolden.self, from: Data(contentsOf: file))
    #expect(reference.feature_spec_version == ContextualCharacterFeatures.version)
    #expect(reference.kind == "fixture")
    if let count { #expect(reference.vectors.count == count) }
    else { #expect(reference.vectors.count >= 750) }
    let model = try LogisticLanguageModel(testFixture: contextModelData())
    for vector in reference.vectors {
        let context = vector.left_context.map(CommittedLeftContext.available) ?? .unavailable
        let features = ContextualCharacterFeatures(vector.raw, leftContext: context)
        #expect(try features.keys(at: vector.index) == vector.features)
        let actual = try model.score(features, at: vector.index)
        #expect(actual.activeIndices == vector.active_indices)
        #expect(abs(actual.logit - vector.logit) < 1e-12)
        #expect(abs(actual.japaneseProbability - vector.p_ja) < 1e-12)
    }
}

@Suite struct ContextualLanguageTests {
    @Test func frozenV2Golden() throws {
        try checkContextGolden(autoMixedRepositoryFile(contextFixtureRoot + "feature_v2_golden.json"), count: 128)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_CONTEXT_PARITY_PATH"] != nil,
                   "Run sh Tools/test_auto_mixed_parity.sh for fresh v2 Python results"))
    func freshV2PythonParity() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_CONTEXT_PARITY_PATH"])
        try checkContextGolden(URL(fileURLWithPath: path))
    }

    @Test func preservesV1KeysAndRawBoundaries() throws {
        for raw in ["made", " made", "e\u{301}👩‍💻", "ky"] {
            for context in [CommittedLeftContext.unavailable, .available(""), .available("I "), .available("明日")] {
                let v2 = ContextualCharacterFeatures(raw, leftContext: context)
                #expect(v2.scalarCount == raw.unicodeScalars.count)
                for index in 0..<v2.scalarCount {
                    let keys = try v2.keys(at: index)
                    #expect(try keys.filter { !$0.hasPrefix("[\"ctx\",") } == AnchoredCharacterFeatures(raw).keys(at: index))
                    #expect(Set(keys).count == keys.count)
                }
            }
        }
        let features = ContextualCharacterFeatures("made", leftContext: .available("I "))
        #expect(try features.keys(at: 0).contains("[\"char\",-1,[\"BOS\"]]"))
        #expect(try features.keys(at: 0).contains("[\"ctx\",\"char\",-1,[\"CHAR\",\" \"]]"))
        let splitSpace = ContextualCharacterFeatures(" made", leftContext: .available("I"))
        #expect(try splitSpace.keys(at: 1).contains("[\"char\",-1,[\"CHAR\",\" \"]]"))
        #expect(try splitSpace.keys(at: 1) != features.keys(at: 0))
        #expect(try ContextualCharacterFeatures("ma").keys(at: 1) != ContextualCharacterFeatures("made").keys(at: 1))
        #expect(throws: AutoMixedError.invalidRange) { try features.keys(at: 4) }
    }

    @Test func missingEmptyAndUnicodeScalarLimit() throws {
        #expect(!CommittedLeftContext.unavailable.isAvailable)
        #expect(CommittedLeftContext.available("").isAvailable)
        let missing = try ContextualCharacterFeatures("made").keys(at: 0)
        let empty = try ContextualCharacterFeatures("made", leftContext: .available("")).keys(at: 0)
        #expect(missing != empty)
        #expect(missing.count == 62)
        #expect(empty.contains("[\"ctx\",\"boundary\",\"empty\"]"))
        let text = "secret-prefix" + String(repeating: "👩‍💻e\u{301}", count: 8) + " "
        let context = CommittedLeftContext.available(text)
        #expect(context.text?.unicodeScalars.count == 30)
        let suffix = String(String.UnicodeScalarView(text.unicodeScalars.suffix(30)))
        #expect(try ContextualCharacterFeatures("made", leftContext: context).keys(at: 0)
                == ContextualCharacterFeatures("made", leftContext: .available(suffix)).keys(at: 0))
        #expect(try ContextualCharacterFeatures("made", leftContext: .available("é")).keys(at: 0)
                != ContextualCharacterFeatures("made", leftContext: .available("e\u{301}")).keys(at: 0))
        #expect(!String(reflecting: context).contains("secret-prefix"))
        #expect(String(reflecting: input("made", context)) == "LanguageJudgmentInput(<redacted>)")
    }

    @Test func versionsCannotBeMixedAndFixturesAreNotProduction() throws {
        let v1 = try LogisticLanguageModel(testFixture: languageFixtureData())
        let v2 = try LogisticLanguageModel(testFixture: contextModelData())
        #expect(throws: LanguageModelError.unsupportedVersion) { try v1.score(ContextualCharacterFeatures("made"), at: 0) }
        #expect(throws: LanguageModelError.unsupportedVersion) { try v2.score(AnchoredCharacterFeatures("made"), at: 0) }
        #expect(throws: LanguageModelError.unsupportedVersion) { try ContextualLanguageSegmenter(model: v1) }
        #expect(throws: LanguageModelError.fixtureNotAllowed) { try LogisticLanguageModel(data: contextModelData()) }
        for mutate: (inout [String: Any]) -> Void in [
            { $0["schema_version"] = 1 }, { $0["feature_spec_version"] = AnchoredCharacterFeatures.version },
            { $0["feature_spec_version"] = "unknown-v3" },
            { $0["thresholds"] = ["enter_ja": 0.9, "hold_ja": 0.65] }
        ] {
            #expect(throws: (any Error).self) { try LogisticLanguageModel(testFixture: contextModelData(mutate)) }
        }
        for (field, value): (String, Any) in [("enter_ja_without_context", 0.89), ("minimum_ja", 1.01),
                                              ("minimum_path_margin", -1), ("unknown", 0)] {
            #expect(throws: (any Error).self) {
                try LogisticLanguageModel(testFixture: contextModelData {
                    var policy = $0["thresholds"] as! [String: Any]
                    policy[field] = value
                    $0["thresholds"] = policy
                })
            }
        }
    }

    @Test func artificialContextContrastIsNotAnAccuracyEvaluation() throws {
        let segmenter = try ContextualLanguageSegmenter(model: LogisticLanguageModel(testFixture: contextModelData()))
        // Intentional artificial weights prove context reaches LR and decoding, not language quality.
        for raw in ["made", "no", "to", "name"] {
            let english = try segmenter.judge(input(raw, .available("I ")))
            let japanese = try segmenter.judge(input(raw, .available("明日")))
            let missing = try segmenter.judge(input(raw))
            #expect(english.hypotheses.map(\.kind) == [.raw])
            #expect(japanese.hypotheses.map(\.kind) == [.japaneseRoman])
            #expect(missing.hypotheses.map(\.kind) == [.unresolved])
            #expect(try japanese.hypotheses.map(\.sourceRange) == [ScalarRange(0, raw.unicodeScalars.count)])
            #expect(japanese.safeSpans.map(\.kind) == [.unresolved])
        }
    }

    @Test func missingContextThresholdIsDataDrivenWithoutAWordList() throws {
        let conservative = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.95))
        let adjusted = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.95, missing: 0.94))
        for raw in ["made", "no", "to", "name", "ashitamade", "arbitrary"] {
            #expect(try conservative.judge(input(raw)).hypotheses.map(\.kind) == [.unresolved])
            #expect(try conservative.judge(input(raw, .available(""))).hypotheses.map(\.kind) == [.japaneseRoman])
            #expect(try adjusted.judge(input(raw)).hypotheses.map(\.kind) == [.japaneseRoman])
        }
    }

    @Test func lowConfidenceAndPathMarginHoldRegardlessOfContext() throws {
        for model in [try fixedModel(probability: 0.8), try fixedModel(probability: 0.95, minimum: 0.96),
                      try fixedModel(probability: 0.95, margin: 20)] {
            let segmenter = try ContextualLanguageSegmenter(model: model)
            #expect(try segmenter.judge(input("made", .available("明日"))).hypotheses.map(\.kind) == [.unresolved])
        }
        let accepted = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.95, margin: 10))
        #expect(try accepted.judge(input("made", .available("明日"))).hypotheses.map(\.kind) == [.japaneseRoman])
        // RAW hard masks are inside the block: two transition penalties must be subtracted.
        let bounded = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.95, margin: 10))
        #expect(try bounded.judge(input("AAmadeBB", .available("明日"))).hypotheses.map(\.kind) == [.raw, .unresolved, .raw])
    }

    @Test func contextDoesNotChangeRawOffsetsOrHardProtections() throws {
        let raw = "👩‍💻 made https://example.test/a API e\u{301}"
        let segmenter = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.999))
        let result = try segmenter.judge(input(raw, .available("明日")))
        let map = TextOffsetMap(raw)
        try MixedMarkedTextRenderer.validate(spans: result.hypotheses, source: map)
        #expect(try MixedMarkedTextRenderer.render(raw: raw, spans: result.safeSpans).text == raw)
        let protections = ProtectedSpanDetector.detect(raw).scalars
        for span in result.hypotheses where span.kind == .japaneseRoman {
            #expect(protections[span.sourceRange.lowerBound..<span.sourceRange.upperBound].allSatisfy { $0 == .inferred })
        }
        #expect(try segmenter.judge(input("")).hypotheses.isEmpty)
    }

    @Test func contextOnlyChangesAndFocusChangesInvalidateResults() throws {
        let focus = UUID()
        let original = LanguageJudgmentInput(raw: "made", leftCommittedContext: .available("I "), focusIdentity: focus, revision: 1)
        let segmenter = try ContextualLanguageSegmenter(model: fixedModel(probability: 0.95))
        let result = try segmenter.judge(original)
        #expect(result.isCurrent(for: original))
        for next in [
            LanguageJudgmentInput(raw: "made", leftCommittedContext: .available("明日"), focusIdentity: focus, revision: 1),
            LanguageJudgmentInput(raw: "made", focusIdentity: focus, revision: 1),
            LanguageJudgmentInput(raw: "made", leftCommittedContext: .available("I "), focusIdentity: UUID(), revision: 1),
            LanguageJudgmentInput(raw: "mad", leftCommittedContext: .available("I "), focusIdentity: focus, revision: 2)
        ] {
            #expect(!result.isCurrent(for: next))
        }
    }
}
