@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct JapanesePreferredTests {
    private func fixture(_ probability: Double = 0.8, characters: [String: Double] = [:]) throws -> LogisticLanguageModel {
        let path = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let baseline = log(probability / (1 - probability))
        let weights = Dictionary(uniqueKeysWithValues: characters.map { key, p in
            ("[\"char\",0,[\"CHAR\",\"\(key)\"]]", log(p / (1 - p)) - baseline)
        })
        let vocabulary = weights.keys.sorted()
        object["vocabulary"] = vocabulary
        object["coefficients"] = vocabulary.map { weights[$0]! }
        object["intercept"] = baseline
        object["calibration"] = ["a": 1, "c": 0]
        object["decoder"] = ["switch_penalty": 0]
        object["thresholds"] = ["enter_ja": 0.9, "enter_ja_without_context": 0.98,
                                "hold_ja": 0.65, "minimum_ja": 0.55, "minimum_path_margin": 1.2]
        return try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
    }

    private func segmenter(_ model: LogisticLanguageModel, words: String = "note\t10\nmade\t10\nname\t10\nno\t10\nto\t10\nmeeting\t10\n",
                           policy: EnglishDecisionPolicy? = nil) throws -> JapanesePreferredSegmenter {
        try JapanesePreferredSegmenter(model: model, lexicon: EnglishLexicon(data: Data(words.utf8)),
                                       policy: policy ?? EnglishDecisionPolicy.bundled(), focus: UUID())
    }

    @Test func bundledLexiconIsLocalVersionedAndStrict() throws {
        let dictionary = try EnglishLexicon.bundled()
        #expect(dictionary.count == 50_957)
        #expect(dictionary.exactLevel("note") == 10)
        #expect(dictionary.exactLevel("NOTE") == 10)
        #expect(dictionary.exactLevel("menu") == 20)
        #expect(dictionary.prefixLevel("mee") == 10)
        #expect(dictionary.exactLevel("asitanote") == nil)
        #expect(dictionary.prefixLevel("asitanote") == nil)
        for raw in ["", "e\u{301}", "café", "'note", "note'", "note word", "note/", String(repeating: "a", count: 33)] {
            #expect(dictionary.exactLevel(raw) == nil)
            #expect(dictionary.prefixLevel(raw) == nil)
        }
        for file in ["", "word\t0\n", "Word\t10\n", "note\t10\nnote\t20\n", "bad word\t10\n", "note\t10\t20\n"] {
            #expect(throws: (any Error).self) { try EnglishLexicon(data: Data(file.utf8)) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            EnglishLexicon.resource("english-policy", extension: "json"))) as? [String: Any])
        object["commonEntryMaximumJapaneseMean"] = 1.5
        #expect(throws: EnglishLexiconError.invalidPolicy) {
            try EnglishDecisionPolicy(data: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func japaneseDefaultRequiresRomanValidityNotAnEnglishSubstringScan() throws {
        let model = try fixture()
        let preferred = try segmenter(model)
        for raw in ["made", "name", "no", "to", "sushi", "asitanote", "asitanotenki"] {
            #expect(try preferred.segment(raw).allSatisfy { $0.kind == .japaneseRoman }, "fixture: \(raw)")
            #expect(try TrainedMixedSegmenter(model: model, focus: UUID()).segment(raw).allSatisfy { $0.kind == .unresolved })
        }
        let weak = try segmenter(fixture(0.1))
        #expect(try weak.segment("asitanote").map(\.kind) == [.japaneseKana])
        #expect(try weak.segment("note").map(\.kind) == [.raw])
        // Dictionary matches remain conditional, including the ambiguous words.
        #expect(try weak.segment("made").map(\.kind) == [.raw])
        #expect(try preferred.segment("made").map(\.kind) == [.japaneseRoman])
        for raw in ["abcai", "asitaqz", "sushibx", "https://example.com/asita", "name@example.com", "file_name"] {
            #expect(try !preferred.segment(raw).contains { $0.kind == .japaneseRoman || $0.kind == .japaneseKana })
        }
    }

    @Test func wordCommonnessPrefixesAndDataPolicyChangeEnglishAdmission() throws {
        let low = try segmenter(fixture(0.1))
        for raw in ["mee", "meet", "meeti", "meeting"] {
            #expect(try low.segment(raw).map(\.kind) == [.raw])
        }
        low.reset()
        #expect(try low.segment("me").map(\.kind) == [.japaneseKana])
        #expect(try !low.segment("mee ").contains { $0.kind == .raw })
        let unusual = try segmenter(fixture(0.1), words: "meeting\t35\n")
        #expect(try unusual.segment("mee").map(\.kind) == [.japaneseKana])
        #expect(try unusual.segment("meeting").map(\.kind) == [.raw])
        let moderate = try segmenter(fixture(0.45), words: "note\t10\n")
        #expect(try moderate.segment("note").map(\.kind) == [.raw])
        #expect(try segmenter(fixture(0.45), words: "note\t35\n").segment("note").map(\.kind) == [.japaneseKana])
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            EnglishLexicon.resource("english-policy", extension: "json"))) as? [String: Any])
        object["commonEntryMaximumJapaneseMean"] = 0.4
        let adjusted = try EnglishDecisionPolicy(data: JSONSerialization.data(withJSONObject: object))
        #expect(try segmenter(fixture(0.45), policy: adjusted).segment("note").map(\.kind) == [.japaneseKana])
    }

    @Test func englishHysteresisOnlyKeepsRelatedEditsAndClearsOnLifecycle() throws {
        // Hand-authored words/scores isolate hysteresis, not real English accuracy.
        let model = try fixture(0.48, characters: ["a": 0.99])
        let words = "ken\t10\nkena\t10\nkenaa\t10\n"
        let preferred = try segmenter(model, words: words)
        #expect(try preferred.segment("ken").map(\.kind) == [.raw])
        #expect(try preferred.segment("kena").map(\.kind) == [.raw])
        preferred.reset()
        #expect(try preferred.segment("kena").map(\.kind) != [.raw])
        _ = try preferred.segment("X ken")
        #expect(try preferred.segment("X kena").last?.kind == .raw)
        #expect(try preferred.segment("Y kena").last?.kind != .raw)
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: preferred, converter: MixedSessionConverter(
            bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true))
        for action: MixedInputEvent in [.enter, .backspace] {
            try engine.replaceRaw("ken")
            #expect(preferred.retainedEnglishRegionCount == 1)
            if case .backspace = action { try engine.replaceRaw("n"); try engine.handle(action) }
            else { try engine.handle(action) }
            #expect(preferred.retainedEnglishRegionCount == 0)
        }
        try engine.replaceRaw("ken")
        engine.cancel()
        #expect(preferred.retainedEnglishRegionCount == 0)
        _ = try preferred.segment("ken")
        #expect(throws: AutoMixedError.invalidRange) { try preferred.segment(String(repeating: "a", count: 4097)) }
        #expect(preferred.retainedEnglishRegionCount == 0)
    }

    @Test func contextFallbackStillRequiresCurrentRawEnglishEvidence() throws {
        // Artificial high JA scores exist even without context: dictionary membership
        // alone must not bypass the existing English gate or create substring matches.
        let preferred = try JapanesePreferredSegmenter(model: fixture(0.99),
            lexicon: EnglishLexicon(data: Data("apple\t10\napplication\t10\n".utf8)),
            policy: .bundled(), context: .available("明日"), focus: UUID())
        for raw in ["app", "appl", "apple", "asitaapple"] {
            preferred.reset()
            #expect(try !preferred.segment(raw).contains { $0.kind == .raw })
        }
    }

    @Test func protectedAndUnicodeRangesStayCoveredAndReadingSuffixIsReversible() throws {
        let preferred = try segmenter(fixture(0.1))
        for raw in ["APIxyz", "APIasita", "👩‍💻 e\u{301} sushi note", "asita  https://example.com", "", "asita_n"] {
            let spans = try preferred.segment(raw)
            try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
            let restored = try MixedMarkedTextRenderer.render(raw: raw, spans: spans, rawPreview: true)
            #expect(restored.text.unicodeScalars.elementsEqual(raw.unicodeScalars))
        }
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true)
        let engine = MixedCompositionEngine(segmenter: preferred, converter: converter)
        try engine.replaceRaw("made sushi 👩‍💻 asitan")
        #expect(try engine.markedText().text == "made すし 👩‍💻 あしたn")
        #expect(!engine.usedRawFallback)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == "made sushi 👩‍💻 asitan")
        #expect(bridge.activeChildCount == 0)
    }

    @Test func embeddedEnglishRequiresCompleteWordsAndIndependentJapaneseFlanks() throws {
        let chars = ["n": 0.1, "o": 0.1, "t": 0.1, "e": 0.1]
        let preferred = try segmenter(fixture(0.99, characters: chars))
        for (raw, expected) in [("kyanoteha", ["kya", "note", "ha"]),
                                ("noteha", ["note", "ha"]), ("kyanote", ["kya", "note"])] {
            preferred.reset()
            let spans = try preferred.segment(raw)
            #expect(try spans.map { try TextOffsetMap(raw).slice($0.sourceRange) } == expected)
            #expect(try spans.filter { $0.kind == .raw }.map { try TextOffsetMap(raw).slice($0.sourceRange) } == ["note"])
        }
        // Complete words only, never a two-letter match or an embedded dictionary prefix.
        for raw in ["kyatoha", "kyanotha"] {
            preferred.reset()
            #expect(try !preferred.segment(raw).contains { $0.kind == .raw })
        }
        let weakFlanks = try segmenter(fixture(0.6, characters: chars))
        #expect(try !weakFlanks.segment("kyanoteha").contains { $0.kind == .raw })
        let pending = try segmenter(fixture(0.99, characters: chars.merging(["g": 0.55]) { _, right in right }))
        #expect(try pending.segment("kyanoteg").map(\.kind) == [.japaneseRoman, .raw, .japaneseKana])
        // Deleting a flank vowel must not manufacture an internal incomplete Japanese run.
        for raw in ["kynoteha", "kyanotexha"] {
            let spans = try preferred.segment(raw)
            for span in spans where span.kind == .japaneseRoman || span.kind == .japaneseKana {
                let parsed = try #require(RomanSpanReading.parse(TextOffsetMap(raw).slice(span.sourceRange)))
                #expect(parsed.suffix.isEmpty || span.sourceRange.upperBound == raw.unicodeScalars.count)
            }
        }
        let unicode = "👩‍💻e\u{301} kyanoteha"
        let spans = try preferred.segment(unicode)
        #expect(spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(9, 13)) })
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(unicode))
        #expect(try MixedMarkedTextRenderer.render(raw: unicode, spans: spans, rawPreview: true).text == unicode)
        let protectedRaw = "https://example.com/kyanoteha"
        #expect(try preferred.segment(protectedRaw).map(\.kind) == [.literal])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func embeddedMeetingKeepsEnglishBetweenCompleteJapaneseRuns() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let raw = "asitahameetinggaarimasu"
        // The whole string happens to be valid roman input across meeting + ga.
        #expect(RomanSpanReading.parse(raw)?.suffix == "")
        let spans = try preferred.segment(raw)
        #expect(spans.map(\.sourceRange) == [try ScalarRange(0, 7), try ScalarRange(7, 14), try ScalarRange(14, 23)])
        #expect(spans.map(\.kind) == [.japaneseRoman, .raw, .japaneseRoman])
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: preferred, converter: MixedSessionConverter(
            bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true))
        try engine.replaceRaw(raw)
        #expect(try engine.markedText().text == "明日はmeetingがあります")
        #expect(!engine.usedRawFallback)
        #expect(engine.buffer.text == raw)
        // Paste, forward typing and backspace must agree once the full word exists.
        for count in Array(14...raw.count) + Array((14...raw.count).reversed()) {
            let partial = String(raw.prefix(count))
            try engine.replaceRaw(partial)
            #expect(try engine.markedText().text.contains("meeting"), "authored trace: \(partial)")
            #expect(engine.spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(7, 14)) })
            #expect(engine.buffer.text == partial)
            #expect(!engine.usedRawFallback)
        }
        try engine.replaceRaw("meetinggaarimasu")
        #expect(try engine.markedText().text == "meetingがあります")
        try engine.replaceRaw(raw)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == raw)
        #expect(bridge.activeChildCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func englishSentencesPreserveAmbiguousWordsUsingCurrentRawContext() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        for raw in ["I made a note", "go to the meeting", "my name is Tom"] {
            preferred.reset()
            let spans = try preferred.segment(raw)
            #expect(spans.allSatisfy { $0.kind == .raw || $0.kind == .gap }, "runtime fixture: \(raw)")
        }
        preferred.reset()
        #expect(try preferred.segment("made").map(\.kind) == [.japaneseKana])
        #expect(try preferred.segment("to").map(\.kind) == [.japaneseKana])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func trainedJapanesePreferredReplay() throws {
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        try replay(bridge)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiJapanesePreferredReplay() throws {
        let bridge = try makeBridge(useZenzai: true)
        defer { bridge.releaseAll() }
        try replay(bridge)
        #expect(bridge.backend == .zenzaiReady)
    }

    private func makeBridge(useZenzai: Bool = false) throws -> ZenzaiSpanBridge {
        try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
                            applicationDirectory: .temporaryDirectory.appendingPathComponent("ja-preferred-\(UUID())"),
                            useZenzai: useZenzai, resources: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map {
                                URL(fileURLWithPath: $0)
                            }, learningEnabled: false)
    }

    private func replay(_ bridge: ZenzaiSpanBridge) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true)
        let engine = MixedCompositionEngine(segmenter: preferred, converter: converter)
        for (raw, expected) in [("asita", "明日"), ("asitan", "明日n"), ("asitano", "明日の"),
                                ("asitanot", "明日のt"), ("asitanote", "明日のて"),
                                ("sushi", "寿司"), ("made", "まで"), ("to", "と"),
                                ("asitahameetinggaarimasu", "明日はmeetingがあります")] {
            preferred.reset()
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == expected, "runtime fixture: \(raw)")
            #expect(engine.buffer.text == raw)
            #expect(!engine.usedRawFallback)
        }
        for raw in ["note", "notes", "meeting", "hello", "design", "menu", "camera", "file", "tomorrow"] {
            preferred.reset()
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == raw, "runtime fixture: \(raw)")
            #expect(engine.spans.map(\.kind) == [.raw])
        }
        for raw in ["no", "name", "asitanotenki"] {
            preferred.reset()
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text != raw)
            #expect(!engine.spans.contains { $0.kind == .raw || $0.kind == .unresolved })
        }
        for raw in ["meetingdesu", "kyoumeetingdesu", "sushi meeting"] {
            preferred.reset()
            try engine.replaceRaw(raw)
            let display = try engine.markedText().text
            #expect(display != raw)
            #expect(display.contains("meeting"))
            #expect(!engine.usedRawFallback)
        }
        try engine.replaceRaw("sushi")
        try engine.handle(.tab())
        #expect(engine.selectionOptions.contains { $0.text == "寿司" })
        try engine.handle(.escape)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == "sushi")
        #expect(bridge.activeChildCount == 0)
        #expect(preferred.retainedEnglishRegionCount == 0)
    }
}
