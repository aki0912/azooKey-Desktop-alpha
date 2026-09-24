@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct PendingRomanTailTests {
    // Artificial scores isolate the display policy. They are not trained accuracy evidence.
    private func fixture(prefix: Double = 0.995, tail: Double = 0.8, hold: Double = 0.65,
                         minimum: Double = 0.55, margin: Double = 1.2,
                         enter: Double = 0.9, withoutContext: Double = 0.98) throws -> LogisticLanguageModel {
        let path = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let keys = ["n", "k", "h", "x"].map { "[\"ngram\",2,0,[[\"CHAR\",\"\($0)\"],[\"EOS\"]]]" }.sorted()
        let baseline = log(prefix / (1 - prefix))
        object["vocabulary"] = keys
        object["coefficients"] = keys.map { _ in log(tail / (1 - tail)) - baseline }
        object["intercept"] = baseline
        object["calibration"] = ["a": 1, "c": 0]
        object["decoder"] = ["switch_penalty": 0]
        object["thresholds"] = ["enter_ja": enter, "enter_ja_without_context": withoutContext,
                                "hold_ja": hold, "minimum_ja": minimum, "minimum_path_margin": margin]
        return try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
    }

    private func segmenter(_ model: LogisticLanguageModel,
                           context: CommittedLeftContext = .unavailable) throws -> TrainedMixedSegmenter {
        try TrainedMixedSegmenter(model: model, context: context, focus: UUID())
    }

    @Test func completedPrefixCanCarryOnlyAValidPendingTail() throws {
        let model = try fixture()
        let adapter = try segmenter(model)
        for (raw, prefix, suffix) in [("asitan", "asita", "n"), ("asitak", "asita", "k"),
                                       ("asitash", "asita", "sh"), ("gakk", "ga", "kk"), ("asitanx", "asita", "nx")] {
            let input = LanguageJudgmentInput(raw: raw, focusIdentity: UUID(), revision: 0)
            #expect(try ContextualLanguageSegmenter(model: model).judge(input).hypotheses.map(\.kind) == [.unresolved])
            #expect(try adapter.segment(raw).map(\.kind) == [.japaneseRoman])
            let parsed = try #require(RomanSpanReading.parse(raw))
            #expect(parsed.prefix == prefix)
            #expect(parsed.suffix == suffix)
        }
        for raw in ["n", "sh", "asitaqz", "asitabx", "asitaN", "abcai"] {
            #expect(try !adapter.segment(raw).contains { $0.kind == .japaneseRoman }, "fixture: \(raw)")
        }
        // A terminal quote is a separate protected literal, not part of the roman run.
        #expect(try adapter.segment("asita'").map(\.kind) == [.japaneseRoman, .literal])
    }

    @Test func currentEvidenceAndExportedThresholdsControlAdmission() throws {
        for model in [
            try fixture(prefix: 0.97), try fixture(tail: 0.6),
            try fixture(hold: 0.85), try fixture(minimum: 0.85), try fixture(margin: 40),
            try fixture(withoutContext: 1)
        ] {
            #expect(try !segmenter(model).segment("asitan").contains { $0.kind == .japaneseRoman })
        }
        // The existing decoder can already accept asita followed by a RAW n. Do not
        // expand that Japanese span over new RAW evidence through the pending-tail rule.
        let split = try segmenter(fixture(tail: 0.4)).segment("asitan")
        #expect(split.map(\.kind) == [.japaneseRoman, .raw])
        #expect(try split.map(\.sourceRange) == [ScalarRange(0, 5), ScalarRange(5, 6)])
        // Context availability still selects the same model-provided entry threshold.
        let model = try fixture(prefix: 0.95, enter: 0.94)
        #expect(try segmenter(model).segment("asitan").map(\.kind) == [.unresolved])
        #expect(try segmenter(model, context: .available("")).segment("asitan").map(\.kind) == [.japaneseRoman])
    }

    @Test func internalTailsProtectionsAndUnicodeBoundariesArePreserved() throws {
        let adapter = try segmenter(fixture())
        for raw in ["asitan ", "asitan API", "https://example.com/asitan", "asitan@example.com", "file_asitan", "asitan.txt"] {
            #expect(try !adapter.segment(raw).contains { $0.kind == .japaneseRoman }, "fixture: \(raw)")
        }
        let prefix = "👩‍💻 e\u{301} "
        let raw = prefix + "asitan"
        let spans = try adapter.segment(raw)
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
        let last = try #require(spans.last)
        #expect(last.kind == .japaneseRoman)
        #expect(last.sourceRange == (try ScalarRange(prefix.unicodeScalars.count, raw.unicodeScalars.count)))
        #expect(try TextOffsetMap(raw).slice(last.sourceRange) == "asitan")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil,
                   "Requires the explicitly selected trained v2 artifact"))
    func trainedModelPendingTailAndEnglishRegressions() throws {
        let model = try runtimeModel()
        let adapter = try segmenter(model)
        for raw in ["asita", "asitan", "asitano", "asitak", "asitash"] {
            #expect(try adapter.segment(raw).map(\.kind) == [.japaneseRoman], "fixture: \(raw)")
        }
        // No spelling correction: the extra s in assitan is not deleted to force 明日.
        for raw in ["assitan", "asian", "ash", "shin", "names", "made", "no", "to", "name", "making", "design", "tomorrow",
                    "asitan ", "asitanx", "sushin", "https://example.com/asitan"] {
            #expect(try !adapter.segment(raw).contains { $0.kind == .japaneseRoman }, "fixture: \(raw)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil,
                   "Requires the explicitly selected trained v2 artifact"))
    func dictionaryReplayEditingCommitAndRawRecovery() throws {
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
                                         applicationDirectory: .temporaryDirectory.appendingPathComponent("pending-test-\(UUID())"),
                                         useZenzai: false, learningEnabled: false)
        defer { bridge.releaseAll() }
        try replay(model: runtimeModel(), bridge: bridge)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil,
                   "Requires the selected trained v2 artifact and real pinned GGUF"))
    func realZenzaiPendingTailReplay() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"])
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
                                         applicationDirectory: .temporaryDirectory.appendingPathComponent("pending-zenz-\(UUID())"),
                                         useZenzai: true, resources: URL(fileURLWithPath: path), learningEnabled: false)
        defer { bridge.releaseAll() }
        try replay(model: runtimeModel(), bridge: bridge)
        #expect(bridge.backend == .zenzaiReady)
    }

    private func runtimeModel() throws -> LogisticLanguageModel {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        return try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func replay(model: LogisticLanguageModel, bridge: ZenzaiSpanBridge) throws {
        let session = UUID()
        let converter = MixedSessionConverter(bridge: bridge, sessionID: session)
        let engine = MixedCompositionEngine(segmenter: try segmenter(model), converter: converter)
        try engine.replaceRaw("asita")
        #expect(try engine.markedText().text == "明日")
        try engine.handle(.insert("n"))
        #expect(engine.buffer.text == "asitan")
        #expect(try engine.markedText().text == "明日n")
        let result = try #require(converter.lastResults.values.first)
        #expect(result.convertedRange == (try ScalarRange(0, 5)))
        #expect(result.suffixRange == (try ScalarRange(5, 6)))
        #expect(result.candidates.allSatisfy { $0.text.hasSuffix("n") })
        try engine.handle(.insert("o"))
        #expect(try engine.markedText().text == "明日の")
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "明日n")
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "明日")
        try engine.replaceRaw("asitan")
        #expect(try engine.markedText().text == "明日n")
        #expect(try engine.handle(.enter).commit?.text == "明日n")
        #expect(engine.buffer.isEmpty)
        #expect(bridge.activeChildCount == 0)
        try engine.replaceRaw("asitan")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "asitan")
        #expect(try engine.handle(.enter).commit?.text == "asitan")
        try engine.replaceRaw("asitan")
        try engine.replaceRaw("asian")
        #expect(try engine.markedText().text == "asian")
        #expect(engine.buffer.text == "asian")
        #expect(bridge.activeChildCount == 0)
        #expect(!engine.usedRawFallback)
    }
}
