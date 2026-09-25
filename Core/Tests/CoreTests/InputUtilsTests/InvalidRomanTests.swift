@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct InvalidRomanTests {
    private let reported = "zuttotukatteirutodanndannnyuuryokugaosokunarukigasurnndakedo"

    private func fixture(_ probability: Double) throws -> LogisticLanguageModel {
        let path = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["vocabulary"] = [String]()
        object["coefficients"] = [Double]()
        object["intercept"] = log(probability / (1 - probability))
        object["calibration"] = ["a": 1, "c": 0]
        object["thresholds"] = ["enter_ja": 0.99, "enter_ja_without_context": 0.99,
                                "hold_ja": 0.65, "minimum_ja": 0.55, "minimum_path_margin": 1.2]
        return try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
    }

    @Test func recoveryUsesIndependentTableBoundariesAndNeverRepairsKeys() throws {
        for (raw, parts) in [("kigasurnndakedo", ["kigasu", "r", "nndakedo"]),
                             ("kigasurn", ["kigasu", "rn"]),
                             ("kyattornndesu", ["kyatto", "r", "nndesu"]),
                             ("kigasurnnd", ["kigasu", "r", "nnd"])] {
            let runs = try #require(RomanSpanReading.independentRuns(raw, isAtBufferEnd: true), "authored boundary: \(raw)")
            let input = Array(raw)
            #expect(runs.map { String(input[$0.range]) } == parts)
            #expect(runs.map { String(input[$0.range]) }.joined() == raw)
            for run in runs where run.isJapanese {
                let parsed = try #require(RomanSpanReading.parse(String(input[run.range])))
                #expect(!parsed.reading.isEmpty)
                #expect(parsed.suffix.isEmpty || run.range.upperBound == input.count)
            }
        }
        let internalRuns = try #require(RomanSpanReading.independentRuns("kigasurnnd", isAtBufferEnd: false))
        #expect(internalRuns.map(\.isJapanese) == [true, false, true, false])
        // This pinned table retains the apostrophe in the indivisible n' -> ん'
        // segment. Do not invent a finer boundary or silently discard that character.
        for raw in ["asitanx", "kyatto", "kan'i", "kan'iqzdesu", "👩‍💻rn", "e\u{301}rn", "APIrn", "https://example.com"] {
            #expect(RomanSpanReading.independentRuns(raw, isAtBufferEnd: true) == nil)
        }
    }

    @Test func recoveryRequiresJapaneseEvidenceAndPreservesTheBaseline() throws {
        for probability in [0.1, 0.6, 0.8] {
            let model = try fixture(probability)
            let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
            let baseline = try TrainedMixedSegmenter(model: model, focus: UUID())
            let spans = try preferred.segment("kigasurnndakedo")
            if probability >= 0.65 {
                #expect(spans.map(\.kind) == [.japaneseRoman, .raw, .japaneseRoman])
            } else {
                #expect(spans.allSatisfy { $0.kind == .raw || $0.kind == .unresolved })
            }
            #expect(try !baseline.segment("kigasurnndakedo").contains { $0.kind == .japaneseRoman })
        }
        let high = try JapanesePreferredSegmenter(model: fixture(0.999), lexicon: .bundled(), policy: .bundled(), focus: UUID())
        for raw in ["apple", "application", "https://example.com/kigasurnndakedo", "file_kigasurnndakedo", "kigasurnndakedo.txt"] {
            #expect(try !high.segment(raw).contains { $0.kind == .japaneseRoman || $0.kind == .japaneseKana })
        }
        let raw = "👩‍💻e\u{301} kigasurnndakedo"
        let spans = try high.segment(raw)
        #expect(spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(12, 13)) })
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
        #expect(try MixedMarkedTextRenderer.render(raw: raw, spans: spans, rawPreview: true).text == raw)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func trainedJapaneseRunKeepsReadablePartsAroundInvalidRoman() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        // The missing u after r must not discard the independently valid Japanese.
        let spans = try preferred.segment(reported)
        #expect(spans.map(\.sourceRange) == [try ScalarRange(0, 51), try ScalarRange(51, 52), try ScalarRange(52, 60)])
        #expect(spans.map(\.kind) == [.japaneseRoman, .raw, .japaneseRoman])
        #expect(try spans.filter { $0.kind == .raw }.map { try TextOffsetMap(reported).slice($0.sourceRange) } == ["r"])
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(reported))
        #expect(try MixedMarkedTextRenderer.render(raw: reported, spans: spans, rawPreview: true).text == reported)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func dictionaryReplayPreservesJapaneseThroughTypingDeletionAndPaste() throws {
        try replay(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiReplayPreservesJapaneseThroughTypingDeletionAndPaste() throws {
        try replay(useZenzai: true)
    }

    private func replay(useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("invalid-roman-\(UUID())"),
            useZenzai: useZenzai, resources: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map {
                URL(fileURLWithPath: $0)
            }, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context: CommittedLeftContext in [.unavailable, .available("")] {
            let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), context: context, focus: UUID())
            let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true)
            let engine = MixedCompositionEngine(segmenter: preferred, converter: converter, punctuation: .init())
            var prefix = "", japaneseDisplay = ""
            let start = Date()
            for character in reported {
                prefix.append(character)
                try engine.handle(.insert(String(character)))
                #expect(engine.buffer.text == prefix)
                #expect(!engine.usedRawFallback)
                try MixedMarkedTextRenderer.validate(spans: engine.spans, source: engine.buffer.offsets)
                let display = try engine.markedText()
                if prefix.count == 51 { japaneseDisplay = display.text }
                if prefix.count >= 52 {
                    #expect(display.text.hasPrefix(japaneseDisplay + "r"))
                    #expect(converter.lastResults.values.contains { $0.convertedRange == (try? ScalarRange(0, 51)) && $0.fallback == nil })
                }
            }
            let display = try engine.markedText()
            #expect(display.text.filter(\.isASCII) == "r")
            #expect(display.text.hasSuffix("んだけど"))
            let rawRun = try #require(display.runs.first { $0.span.sourceRange == (try? ScalarRange(51, 52)) })
            #expect(!rawRun.isAtomic)
            #expect(display.rawScalarOffset(forDisplayUTF16: rawRun.displayRange.location) == 51)
            #expect(display.displayOffset(forRawScalar: 52) == rawRun.displayRange.upperBound)
            #expect(converter.lastResults.values.contains { $0.convertedRange == (try? ScalarRange(52, 60)) && $0.fallback == nil })
            #expect(bridge.sessionLimitHitCount == 0)
            print("Authored invalid-roman replay zenzai=\(useZenzai) contextAvailable=\(context.isAvailable) seconds=\(Date().timeIntervalSince(start)) display=\(display.text)")
            try engine.handle(.insert("."))
            #expect(try engine.markedText().text == display.text + "。")
            try engine.handle(.backspace)
            for _ in 0..<8 { try engine.handle(.backspace) }
            #expect(try engine.markedText().text == japaneseDisplay + "r")
            for character in "nndakedo" { try engine.handle(.insert(String(character))) }
            #expect(try engine.markedText().text == display.text)
            #expect(try engine.handle(.enter).commit?.text == display.text)
            #expect(bridge.activeChildCount == 0)
            try engine.replaceRaw(reported)
            #expect(try engine.markedText().text == display.text)
            try engine.handle(.escape)
            #expect(try engine.handle(.enter).commit?.text == reported)
            #expect(bridge.activeChildCount == 0)
            // Adding the missing key removes the raw island without changing the input.
            let corrected = reported.replacingOccurrences(of: "surnn", with: "surunn")
            try engine.replaceRaw(corrected)
            #expect(engine.buffer.text == corrected)
            #expect(try !engine.markedText().text.contains(where: \.isASCII))
            #expect(!engine.usedRawFallback)
            engine.cancel()
            #expect(bridge.activeChildCount == 0)
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
