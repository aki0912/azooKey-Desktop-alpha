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

    @Test func bareDottedJapaneseNeedsReadingAndEvidenceWhileExplicitStructuresStayProtected() throws {
        let preferred = try segmenter(fixture())
        let weak = try segmenter(fixture(0.1))
        for raw in ["asita.d", "nihongo.txt", "asita.desu"] {
            let spans = try preferred.segment(raw)
            #expect(spans.first?.kind == .japaneseRoman)
            #expect(try weak.segment(raw).allSatisfy { $0.kind == .literal })
            // The frozen judge and public detector keep the original protection contract.
            #expect(ProtectedSpanDetector.detect(raw).scalars.allSatisfy { $0 == .literal })
            #expect(try TrainedMixedSegmenter(model: fixture(), focus: UUID()).segment(raw).allSatisfy { $0.kind == .literal })
        }
        for raw in ["note.txt", "name.md", "made.d", "readme.mdwohiraku", "qzx.d", "asitan.d",
                    "./asita.d", "https://asita.d", "www.asita.d", "asita@example.com", "asita_d.txt", "v3.2"] {
            #expect(try preferred.segment(raw).allSatisfy { $0.kind == .literal }, "protected: \(raw)")
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
        // Invalid letters now keep only their own raw range. The old whole-token
        // veto erased readable Japanese after a typo; never pass that typo to conversion.
        for (raw, parts) in [("abcai", ["a", "b", "cai"]), ("asitaqz", ["asita", "qz"]), ("sushibx", ["sushi", "bx"])] {
            let spans = try preferred.segment(raw)
            #expect(try spans.map { try TextOffsetMap(raw).slice($0.sourceRange) } == parts)
            for span in spans where span.kind == .japaneseRoman {
                #expect(RomanSpanReading.parse(try TextOffsetMap(raw).slice(span.sourceRange))?.suffix.isEmpty == true)
            }
            #expect(try weak.segment(raw).allSatisfy { $0.kind != .japaneseRoman && $0.kind != .japaneseKana })
        }
        for raw in ["https://example.com/asita", "name@example.com", "file_name"] {
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

    @Test func completedKanaTailRejoinsOnlyWithEvidenceAtEveryPosition() throws {
        // Artificial scores isolate display policy from language model accuracy.
        for raw in ["kaihatu", "soketu"] {
            let model = try fixture(0.995, characters: ["t": 0.9, "u": 0.9])
            let baseline = try TrainedMixedSegmenter(model: model, focus: UUID()).segment(raw)
            #expect(baseline.map(\.kind) == [.japaneseRoman, .japaneseKana])
            let spans = try segmenter(model).segment(raw)
            #expect(spans.map(\.kind) == [.japaneseRoman])
            #expect(spans.first?.sourceRange == (try ScalarRange(0, raw.count)))
        }
        // The mean exceeds hold, but one tail position does not. Keep its preview.
        let uncertain = try fixture(0.995, characters: ["t": 0.6, "u": 0.95])
        #expect(try segmenter(uncertain).segment("kaihatu").map(\.kind)
                == [.japaneseRoman, .japaneseKana])
        for raw in ["kaiha tu", "kaiha_tu", "https://example.com/kaihatu"] {
            let spans = try segmenter(uncertain).segment(raw)
            try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
            #expect(spans.count != 1 || spans.first?.kind != .japaneseRoman,
                    "Must not join a separated or protected reading: \(raw)")
        }
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
            if case .backspace = action { try engine.replaceRaw("n"); try engine.handle(action) } else { try engine.handle(action) }
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

    @Test func embeddedDictionaryWordDoesNotRequireViterbiEndpoints() throws {
        // Authored scores isolate both missing endpoints; these are not accuracy samples.
        for characters in [["n": 0.1, "o": 0.1, "t": 0.1, "e": 0.1, "g": 0.1],
                           ["n": 0.51, "o": 0.1, "t": 0.1, "e": 0.1, "g": 0.1]] {
            let model = try fixture(0.99, characters: characters)
            let preferred = try segmenter(model)
            for raw in ["kyanoteg", "kyanote", "kyanoteha", "kyanoteg"] {
                let spans = try preferred.segment(raw)
                #expect(spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(3, 7)) })
                preferred.reset()
                #expect(try preferred.segment(raw).map(\.sourceRange) == spans.map(\.sourceRange))
                #expect(try preferred.segment(raw).map(\.kind) == spans.map(\.kind))
            }
            #expect(RomanSpanReading.parse("gqzha") == nil)
            for raw in ["kynoteg", "kyanotegqzha", "kyanothg", "https://example.com/kyanoteg", "kyanoteg.txt"] {
                preferred.reset()
                let spans = try preferred.segment(raw)
                let words = try spans.filter { $0.kind == .raw }.map { try TextOffsetMap(raw).slice($0.sourceRange) }
                #expect(!words.contains("note"), "authored negative: \(raw)")
            }
            let raw = "👩‍💻e\u{301} kyanoteg"
            let spans = try preferred.segment(raw)
            #expect(spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(9, 13)) })
            try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
            #expect(try MixedMarkedTextRenderer.render(raw: raw, spans: spans, rawPreview: true).text == raw)
        }
        // Low-confidence Japanese flanks and high-confidence Japanese words still veto matches.
        let weak = try segmenter(fixture(0.6, characters: ["n": 0.1, "o": 0.1, "t": 0.1, "e": 0.1, "g": 0.1]))
        #expect(try !weak.segment("kyanoteg").contains { $0.kind == .raw })
        #expect(try !segmenter(fixture(0.99)).segment("kyanoteg").contains { $0.kind == .raw })
    }

    @Test func wholeDictionaryWordDecisionPrecedesShorterEmbeddedWords() throws {
        let model = try fixture(0.99, characters: ["m": 0.49, "a": 0.42, "d": 0.83, "e": 0.79])
        let preferred = try segmenter(model, words: "mad\t10\nmade\t10\n")
        #expect(try preferred.segment("made").map(\.kind) == [.japaneseKana])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func embeddedMeetingKeepsEnglishBetweenCompleteJapaneseRuns() throws {
        try replayEmbeddedMeeting(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiEmbeddedEnglishTypingRegression() throws {
        try replayEmbeddedMeeting(useZenzai: true)
    }

    private func replayEmbeddedMeeting(useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let raw = "asitahameetinggaarimasu"
        // The whole string happens to be valid roman input across meeting + ga.
        #expect(RomanSpanReading.parse(raw)?.suffix.isEmpty == true)
        let spans = try preferred.segment(raw)
        #expect(spans.map(\.sourceRange) == [try ScalarRange(0, 7), try ScalarRange(7, 14), try ScalarRange(14, 23)])
        #expect(spans.map(\.kind) == [.japaneseRoman, .raw, .japaneseRoman])
        let bridge = try makeBridge(useZenzai: useZenzai)
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
        try engine.replaceRaw("")
        for (index, character) in raw.enumerated() {
            try engine.handle(.insert(String(character)))
            if index >= 13 {
                #expect(try engine.markedText().text.contains("meeting"))
                #expect(engine.spans.contains { $0.kind == .raw && $0.sourceRange == (try? ScalarRange(7, 14)) })
            }
        }
        for _ in 14..<raw.count {
            try engine.handle(.backspace)
            #expect(try engine.markedText().text.contains("meeting"))
        }
        try engine.replaceRaw("meetinggaarimasu")
        #expect(try engine.markedText().text == "meetingがあります")
        try engine.replaceRaw(raw)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == raw)
        #expect(bridge.activeChildCount == 0)
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
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
        // This is a language-decision contract. Trained scores may choose either
        // kana preview or kanji conversion; artificial-score tests fix those gates.
        for (raw, reading) in [("made", "まで"), ("to", "と")] {
            preferred.reset()
            let spans = try preferred.segment(raw)
            #expect(spans.count == 1)
            let span = try #require(spans.first)
            #expect(span.sourceRange == (try ScalarRange(0, raw.unicodeScalars.count)))
            #expect(span.kind == .japaneseKana || span.kind == .japaneseRoman)
            let parsed = try #require(RomanSpanReading.parse(TextOffsetMap(raw).slice(span.sourceRange)))
            #expect(parsed.reading == reading)
            #expect(parsed.suffix.isEmpty)
        }
    }

    @Test func dictionaryRankingForCompleteAmbiguousJapaneseReadings() throws {
        // Bypass language judgment to establish the pinned dictionary's ranking.
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: .temporaryDirectory.appendingPathComponent("dictionary-ranking-\(UUID())"),
            containerURL: nil, context: .init(useZenzai: false, learningEnabled: false))
        for (raw, reading, first) in [("made", "まで", "間で"), ("asitanote", "あしたのて", "明日の手")] {
            let candidates = manager.replaceCompositionFromRaw(raw, leftContext: nil, rightContext: nil, rich: false)
            #expect(manager.convertTarget == reading)
            #expect(candidates.first?.text == first)
            if raw == "made" { #expect(candidates.contains { $0.text == "まで" }) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func trainedJapanesePreferredReplay() throws {
        let bridge = try makeBridge()
        defer { bridge.releaseAll() }
        try replay(bridge, useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiJapanesePreferredReplay() throws {
        let bridge = try makeBridge(useZenzai: true)
        defer { bridge.releaseAll() }
        try replay(bridge, useZenzai: true)
        #expect(bridge.backend == .zenzaiReady)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func pendingNxKeepsJapanesePrefixAndReversibleRaw() throws {
        try replayPendingNx(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiPendingNxKeepsJapanesePrefixAndReversibleRaw() throws {
        try replayPendingNx(useZenzai: true)
    }

    private func replayPendingNx(useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let bridge = try makeBridge(useZenzai: useZenzai)
        defer { bridge.releaseAll() }
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true)
        let engine = MixedCompositionEngine(segmenter: preferred, converter: converter)
        func check(_ raw: String, display: String) throws {
            #expect(engine.buffer.text == raw)
            #expect(try engine.markedText().text == display)
            try MixedMarkedTextRenderer.validate(spans: engine.spans, source: TextOffsetMap(raw))
            #expect(try MixedMarkedTextRenderer.render(raw: raw, spans: engine.spans, rawPreview: true).text == raw)
            #expect(!engine.usedRawFallback)
            // The completed prefix must reach the converter; nx must never be
            // discarded or included in a guessed kanji reading.
            #expect(converter.lastResults.count == 1)
            let result = try #require(converter.lastResults.values.first)
            #expect(result.convertedRange == (try ScalarRange(0, 5)))
            #expect(result.fallback == nil)
            #expect(!result.candidates.isEmpty)
        }
        for character in "asita" { try engine.handle(.insert(String(character))) }
        try check("asita", display: "明日")
        try engine.handle(.insert("n"))
        try check("asitan", display: "明日n")
        try engine.handle(.insert("x"))
        try check("asitanx", display: "明日nx")
        try engine.handle(.backspace)
        try check("asitan", display: "明日n")
        try engine.handle(.backspace)
        try check("asita", display: "明日")
        for character in "nx" { try engine.handle(.insert(String(character))) }
        try check("asitanx", display: "明日nx")
        #expect(try engine.handle(.enter).commit?.text == "明日nx")
        #expect(engine.buffer.isEmpty)
        #expect(bridge.activeChildCount == 0)

        // Reset/paste must agree with typing, independently of prior span kinds.
        try engine.replaceRaw("asitanx")
        try check("asitanx", display: "明日nx")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "asitanx")
        #expect(try engine.handle(.enter).commit?.text == "asitanx")
        #expect(engine.buffer.isEmpty)
        #expect(bridge.activeChildCount == 0)
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }

    private func makeBridge(useZenzai: Bool = false) throws -> ZenzaiSpanBridge {
        try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
                            applicationDirectory: .temporaryDirectory.appendingPathComponent("ja-preferred-\(UUID())"),
                            useZenzai: useZenzai, resources: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map {
                                URL(fileURLWithPath: $0)
                            }, learningEnabled: false)
    }

    private func replay(_ bridge: ZenzaiSpanBridge, useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true)
        let engine = MixedCompositionEngine(segmenter: preferred, converter: converter)
        // The pinned dictionary may rank 手 / 間で first when a trained model
        // admits kanji conversion. Zenzai's exact display contract remains separate.
        let dictionaryAlternatives = ["asitanote": "明日の手", "made": "間で"]
        for (raw, expected) in [("asita", "明日"), ("asitan", "明日n"), ("asitano", "明日の"),
                                ("asitanot", "明日のt"), ("asitanote", "明日のて"),
                                ("sushi", "寿司"), ("made", "まで"), ("to", "と"),
                                ("asitahameetinggaarimasu", "明日はmeetingがあります")] {
            preferred.reset()
            try engine.replaceRaw(raw)
            let display = try engine.markedText().text
            if !useZenzai, let alternative = dictionaryAlternatives[raw] {
                #expect(display == expected || display == alternative, "dictionary fixture: \(raw)")
                #expect(engine.spans.allSatisfy { $0.kind == .japaneseRoman || $0.kind == .japaneseKana })
                let readings = try engine.spans.map {
                    try #require(RomanSpanReading.parse(TextOffsetMap(raw).slice($0.sourceRange)))
                }
                #expect(readings.allSatisfy { $0.suffix.isEmpty })
                #expect(readings.map(\.reading).joined() == (raw == "made" ? "まで" : "あしたのて"))
            } else {
                #expect(display == expected, "runtime fixture: \(raw)")
            }
            #expect(engine.buffer.text == raw)
            try MixedMarkedTextRenderer.validate(spans: engine.spans, source: TextOffsetMap(raw))
            #expect(!engine.usedRawFallback)
            #expect(converter.lastResults.values.allSatisfy { $0.fallback == nil })
            if dictionaryAlternatives[raw] != nil {
                try engine.handle(.escape)
                #expect(try engine.markedText().text == raw)
                #expect(try engine.handle(.enter).commit?.text == raw)
                #expect(bridge.activeChildCount == 0)
            }
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
