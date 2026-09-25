@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct KanaTailTests {
    // Artificial fixture for the kana policy, not a claim about the trained model.
    private func fixture(prefix: Double = 0.995, tail: Double = 0.7, minimum: Double = 0.55,
                         margin: Double = 1.2, enter: Double = 0.9,
                         withoutContext: Double = 0.98, rejectTruncatedPrefix: Bool = false) throws -> LogisticLanguageModel {
        let path = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let baseline = log(prefix / (1 - prefix))
        var weights = Dictionary(uniqueKeysWithValues: [0, -1].map { offset in
            ("[\"ngram\",3,\(offset),[[\"CHAR\",\"t\"],[\"CHAR\",\"e\"],[\"EOS\"]]]",
             log(tail / (1 - tail)) - baseline)
        })
        if rejectTruncatedPrefix {
            weights["[\"ngram\",3,-1,[[\"CHAR\",\"n\"],[\"CHAR\",\"o\"],[\"EOS\"]]]"] = -baseline
        }
        let keys = weights.keys.sorted()
        object["vocabulary"] = keys
        object["coefficients"] = keys.map { weights[$0]! }
        object["intercept"] = baseline
        object["calibration"] = ["a": 1, "c": 0]
        object["decoder"] = ["switch_penalty": 0]
        object["thresholds"] = ["enter_ja": enter, "enter_ja_without_context": withoutContext,
                                "hold_ja": 0.65, "minimum_ja": minimum, "minimum_path_margin": margin]
        return try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
    }

    private func segmenter(_ model: LogisticLanguageModel,
                           context: CommittedLeftContext = .unavailable) throws -> TrainedMixedSegmenter {
        try TrainedMixedSegmenter(model: model, context: context, focus: UUID())
    }

    @Test func finalInputTableSegmentMustBeIndependentAndComplete() throws {
        for (raw, prefix, tail, reading) in [("asitanote", "asitano", "te", "て"),
                                            ("asitanokya", "asitano", "kya", "きゃ"),
                                            ("asitanotte", "asitano", "tte", "って"),
                                            ("asitanonki", "asitano", "nki", "んき")] {
            let split = try #require(RomanSpanReading.splitFinalKana(raw))
            #expect(split.prefix == prefix)
            #expect(split.tail == tail)
            #expect(RomanSpanReading.parse(tail)?.reading == reading)
            #expect(prefix + tail == raw)
        }
        for raw in ["te", "kya", "asitanot", "asitanoteN", "asitanoteqz", "asitanoxte", "👩‍💻te", "asita te"] {
            #expect(RomanSpanReading.splitFinalKana(raw) == nil, "fixture: \(raw)")
        }
    }

    @Test func exportedThresholdsAndBothPrefixSnapshotsGateKana() throws {
        let accepted = try segmenter(fixture()).segment("asitanote")
        #expect(accepted.map(\.kind) == [.japaneseRoman, .japaneseKana])
        #expect(try accepted.map(\.sourceRange) == [ScalarRange(0, 7), ScalarRange(7, 9)])
        for model in [try fixture(prefix: 0.97), try fixture(tail: 0.6), try fixture(tail: 0.4),
                      try fixture(minimum: 0.75), try fixture(margin: 2),
                      try fixture(withoutContext: 1), try fixture(rejectTruncatedPrefix: true)] {
            #expect(try !segmenter(model).segment("asitanote").contains { $0.kind == .japaneseKana })
        }
        let model = try fixture(prefix: 0.95, enter: 0.94)
        #expect(try !segmenter(model).segment("asitanote").contains { $0.kind == .japaneseKana })
        #expect(try segmenter(model, context: .available("")).segment("asitanote").map(\.kind)
                == [.japaneseRoman, .japaneseKana])
        let adapter = try segmenter(fixture())
        for raw in ["asitanote ", "asitanote API", "https://example.com/asitanote", "asitanote@example.com", "file_asitanote"] {
            #expect(try !adapter.segment(raw).contains { $0.kind == .japaneseKana })
        }
        let raw = "👩‍💻 e\u{301} asitanote"
        let spans = try adapter.segment(raw)
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
        #expect(spans.last?.kind == .japaneseKana)
        #expect(try spans.last?.sourceRange == ScalarRange(raw.unicodeScalars.count - 2, raw.unicodeScalars.count))
    }

    @Test func readingOnlyTailUsesNoDictionaryRequestOrLearnableToken() throws {
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID())
        converter.prepare(revision: 1, sourceScalarCount: 9, retaining: [])
        let span = try MixedSpan(sourceRange: ScalarRange(7, 9), kind: .japaneseKana)
        let result = try converter.candidates(for: "te", span: span)
        #expect(result.map(\.text) == ["て"])
        #expect(bridge.candidateRequestCount == 0)
        #expect(bridge.activeChildCount == 0)
        #expect(converter.lastResults.isEmpty)
        let identity = JapaneseSpanIdentity(sessionID: UUID(), compositionID: UUID(), spanID: span.id, revision: 1)
        #expect(throws: JapaneseSpanBridgeError.invalidToken) {
            try bridge.recordCommittedSelection(try #require(result.first?.token), identity: identity)
        }
        for raw in ["tn", "Te", "👩‍💻", "tex"] {
            #expect(try converter.candidates(for: raw, span: span).isEmpty)
        }
        converter.prepare(revision: 2, sourceScalarCount: 10, retaining: [])
        #expect(try converter.candidates(for: "te", span: span).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil,
                   "Requires the selected trained v2 artifact"))
    func trainedModelEnglishContrasts() throws {
        let adapter = try segmenter(runtimeModel())
        for raw in ["note", "notes", "notebook", "asianote", "asitanotea", "asitanote wo", "made", "name", "no", "to",
                    "asitanoten", "asitanotenki", "https://example.com/asitanote"] {
            #expect(try !adapter.segment(raw).contains { $0.kind == .japaneseKana }, "fixture: \(raw)")
        }
    }

    @Test
    func dictionaryKanaReplayAndSelection() throws {
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        try replay(bridge)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil,
                   "Requires the pinned GGUF; classification uses controlled scores"))
    func realZenzaiKanaReplayAndSelection() throws {
        let bridge = try makeBridge(useZenzai: true)
        defer { bridge.releaseAll() }
        try replay(bridge)
        #expect(bridge.backend == .zenzaiReady)
    }

    private func makeBridge(useZenzai: Bool = false) throws -> ZenzaiSpanBridge {
        let resources = ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }
        return try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
                                   applicationDirectory: .temporaryDirectory.appendingPathComponent("kana-tail-\(UUID())"),
                                   useZenzai: useZenzai, resources: resources, learningEnabled: false)
    }

    private func runtimeModel() throws -> LogisticLanguageModel {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        return try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func replay(_ bridge: ZenzaiSpanBridge) throws {
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID())
        // Exercise kana-tail editing with controlled scores. Retraining may legitimately
        // convert all of asitanote; that must not silently remove coverage of this state.
        let engine = MixedCompositionEngine(segmenter: try segmenter(fixture()), converter: converter)
        try engine.replaceRaw("asitano")
        #expect(try engine.markedText().text == "明日の")
        try engine.handle(.insert("t"))
        #expect(try engine.markedText().text == "明日のt")
        try engine.handle(.insert("e"))
        #expect(try engine.markedText().text == "明日のて")
        #expect(engine.buffer.text == "asitanote")
        #expect(engine.spans.map(\.kind) == [.japaneseRoman, .japaneseKana])
        #expect(bridge.activeChildCount == 1)
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "明日のt")
        try engine.handle(.insert("e"))
        try engine.handle(.tab())
        #expect(engine.selectionOptions.contains { $0.text == "あしたの" })
        let count = engine.selectionOptions.count
        for _ in 0..<count where engine.selectionOptions[engine.selectionIndex ?? 0].text != "あしたの" {
            try engine.handle(.tab())
        }
        #expect(try engine.markedText().text == "あしたのて")
        #expect(try engine.handle(.enter).commit == nil)
        #expect(try engine.handle(.enter).commit?.text == "あしたのて")
        #expect(bridge.activeChildCount == 0)
        try engine.replaceRaw("asitanote")
        #expect(try engine.markedText().text == "明日のて")
        #expect(try engine.handle(.enter).commit?.text == "明日のて")
        try engine.replaceRaw("asitanote")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "asitanote")
        #expect(try engine.handle(.enter).commit?.text == "asitanote")
        try engine.replaceRaw("asitanote")
        try engine.replaceRaw("API")
        #expect(try engine.markedText().text == "API")
        #expect(bridge.activeChildCount == 0)
        #expect(!engine.usedRawFallback)
    }
}
