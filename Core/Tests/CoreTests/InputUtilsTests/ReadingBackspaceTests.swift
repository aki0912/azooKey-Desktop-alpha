@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private struct BackspaceSegmenter: LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan] {
        var result: [MixedSpan] = [], offset = 0
        let words = raw.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            if !word.isEmpty {
                let end = offset + word.unicodeScalars.count
                let kind: SpanKind = ["apple", "meeting"].contains(String(word)) ? .raw
                    : RomanSpanReading.parse(String(word)) != nil ? .japaneseRoman : .literal
                result.append(try .init(sourceRange: ScalarRange(offset, end), kind: kind))
                offset = end
            }
            if index + 1 < words.count {
                result.append(try .init(sourceRange: ScalarRange(offset, offset + 1), kind: .gap))
                offset += 1
            }
        }
        return result
    }
}

@MainActor private final class BackspaceConverter: JapaneseSpanConverting {
    var calls = 0, finishes = 0
    var fails = false
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        calls += 1
        if fails { throw AutoMixedError.invalidCandidate }
        let parsed = try #require(RomanSpanReading.parse(raw))
        let text = parsed.reading == "あした" ? "明日" : parsed.reading == "あし" ? "足" : parsed.reading
        return [.init(token: UUID().uuidString, text: text + parsed.suffix)]
    }
    func finishComposition() { finishes += 1 }
}

@Suite @MainActor struct ReadingBackspaceTests {
    @Test func readingUnitsPreserveSpellingOrRoundTripTheResidualKana() throws {
        let editor = RomanReadingBackspaceEditor()
        for (raw, reading) in [("asita", "あし"), ("ashita", "あし"), ("si", ""), ("shi", ""),
                                ("tu", ""), ("tsu", ""), ("kya", ""), ("sha", ""), ("fa", ""),
                                ("kixya", ""), ("xya", ""), ("kitte", "きっ"), ("kanji", "かん"),
                                ("tenki", "てん"), ("kankya", "かん"), ("harike-n", "はりけー"),
                                ("harike-nn", "はりけー"), ("ko-hi-", "こーひ"), ("xtu", ""), ("nn", "")] {
            let result = try #require(editor.deletingLastUnit(in: raw), "authored: \(raw)")
            #expect(result.reading == reading)
            if !reading.isEmpty {
                #expect(RomanSpanReading.parse(result.raw)?.reading == reading)
                #expect(RomanSpanReading.parse(result.raw)?.suffix.isEmpty == true)
            } else { #expect(result.raw.isEmpty) }
        }
        #expect(editor.deletingLastUnit(in: "asita")?.raw == "asi")
        #expect(editor.deletingLastUnit(in: "ashita")?.raw == "ashi")
        #expect(editor.deletingLastUnit(in: "kitte")?.raw.hasPrefix("ki") == true)
        #expect(editor.deletingLastUnit(in: "kanji")?.raw.hasPrefix("ka") == true)
        for (initial, readings) in [("kitte", ["きっ", "き", ""]), ("kanji", ["かん", "か", ""])] {
            var raw = initial
            for reading in readings {
                let result = try #require(editor.deletingLastUnit(in: raw))
                #expect(result.reading == reading)
                raw = result.raw
            }
        }
        for raw in ["", "n", "asitan", "asit", "asitanx", "https://example.com", "👩‍💻"] {
            #expect(editor.deletingLastUnit(in: raw) == nil)
        }
    }

    @Test func optInPreviewRepeatDeleteResumeAndRawEscape() throws {
        let converter = BackspaceConverter()
        let engine = MixedCompositionEngine(segmenter: BackspaceSegmenter(), converter: converter,
            backspaceEditor: RomanReadingBackspaceEditor())
        try engine.replaceRaw("asita")
        #expect(try engine.markedText().text == "明日")
        let calls = converter.calls
        try engine.handle(.backspace)
        #expect(engine.buffer.text == "asi")
        #expect(try engine.markedText().text == "あし")
        #expect(converter.calls == calls)
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "あ")
        #expect(try engine.handle(.enter).commit?.text == "あ")
        try engine.replaceRaw("asita")
        try engine.handle(.backspace)
        try engine.handle(.space)
        #expect(try engine.markedText().text == "足 ")
        engine.cancel()
        try engine.replaceRaw("asita")
        try engine.handle(.backspace)
        try engine.handle(.insert("ta"))
        #expect(try engine.markedText().text == "明日")
        try engine.handle(.backspace)
        try engine.handle(.tab())
        #expect(engine.selectionOptions.first?.text == "足")
        try engine.handle(.enter) // Adopt candidate, then invalidate it by editing.
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "あ")
        #expect(engine.selectionOptions.isEmpty)
        engine.cancel()
        try engine.replaceRaw("kitte")
        try engine.handle(.backspace)
        let edited = engine.buffer.text
        #expect(try engine.markedText().text == "きっ")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == edited)
        try engine.handle(.backspace)
        #expect(engine.state == .rawPreview)
        #expect(try engine.markedText().text == String(edited.dropLast()))
        #expect(try engine.handle(.enter).commit?.text == String(edited.dropLast()))
        let legacy = MixedCompositionEngine(segmenter: BackspaceSegmenter(), converter: BackspaceConverter())
        try legacy.replaceRaw("asita")
        try legacy.handle(.backspace)
        #expect(legacy.buffer.text == "asit") // Old callers are unchanged.
    }

    @Test func mixedRangesPendingLettersAndFailureRecoveryRemainSafe() throws {
        let converter = BackspaceConverter()
        let engine = MixedCompositionEngine(segmenter: BackspaceSegmenter(), converter: converter,
            backspaceEditor: RomanReadingBackspaceEditor())
        try engine.replaceRaw("asita apple asita")
        let previousIDs = engine.spans.dropLast().map(\.id)
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "明日 apple あし")
        #expect(engine.spans.dropLast().map(\.id) == previousIDs)
        try MixedMarkedTextRenderer.validate(spans: engine.spans, source: engine.buffer.offsets)
        for (raw, expected) in [("apple", "appl"), ("https://example.com", "https://example.co"),
                                ("👩‍💻e\u{301}", "👩‍💻"), ("👩‍💻", "")] {
            try engine.replaceRaw(raw)
            try engine.handle(.backspace)
            #expect(engine.buffer.text == expected)
        }
        try engine.replaceRaw("asitan")
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "明日")
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "あし")
        engine.cancel()
        converter.fails = true
        try engine.replaceRaw("asita")
        #expect(engine.usedRawFallback)
        try engine.handle(.backspace)
        #expect(engine.buffer.text == "asit")
        #expect(try engine.markedText().text == "asit")
    }

    @Test func acknowledgedEditedRawAndUnacknowledgedDeletesHaveDifferentRecoveryContracts() throws {
        let epoch = UUID()
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: epoch))
        let session = AutoMixedServerSession(epoch: epoch) { _ in
            MixedCompositionEngine(segmenter: BackspaceSegmenter(), converter: BackspaceConverter(),
                backspaceEditor: RomanReadingBackspaceEditor())
        }
        func key(_ text: String, _ code: UInt16 = 0) -> KeyEventCore {
            .init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)
        }
        func send(_ id: UInt64, _ action: AutoMixedAction) throws -> ConverterServerResponse {
            try session.handle(.init(serverEpoch: epoch, focusID: ledger.focusID, operationID: id,
                startsFocus: id == 1, action: action))
        }
        let first = try #require(send(1, .key(key("asita"))).autoMixed)
        let acceptedFirst = ledger.acceptSnapshot(first)
        #expect(acceptedFirst)
        ledger.recordKey(key("\u{7f}", 51), operationID: 2)
        #expect(ledger.recoveryRaw() == "asit") // No unacknowledged language inference.
        let deleted = try send(2, .key(key("\u{7f}", 51)))
        let acceptedDeletion = ledger.acceptSnapshot(try #require(deleted.autoMixed))
        #expect(acceptedDeletion)
        #expect(ledger.recoveryRaw() == "asi")
        #expect(ledger.immediateCommitText(displayed: "あし") == "あし")
        let committed = try send(3, .commit)
        #expect(committed.autoMixed?.commits.first?.text == "あし")
        _ = try send(4, .deactivate)
        ledger.deactivate()
        #expect(ledger.recoveryRaw().isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func dictionaryReadingDeletion() throws { try replay(useZenzai: false) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiReadingDeletion() throws { try replay(useZenzai: true) }

    private func replay(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("reading-backspace-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available("")] {
            let engine = MixedCompositionEngine(segmenter: try JapanesePreferredSegmenter(model: model,
                lexicon: .bundled(), policy: .bundled(), context: context, focus: UUID()),
                converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), leftContext: context.text,
                    allowJapaneseReadingFallback: true), punctuation: .init(leftContext: context),
                backspaceEditor: RomanReadingBackspaceEditor())
            for (raw, expected) in [("asita", "あし"), ("ashita", "あし"), ("kitte", "きっ"),
                                    ("kanji", "かん"), ("kankya", "かん"), ("harike-n", "はりけー")] {
                engine.cancel()
                for character in raw { try engine.handle(.insert(String(character))) }
                try engine.handle(.backspace)
                #expect(!engine.usedRawFallback)
                #expect(try engine.markedText().text == expected, "authored: \(raw)")
                #expect(try engine.handle(.enter).commit?.text == expected)
                #expect(bridge.activeChildCount == 0)
            }
            try engine.replaceRaw("asitanx")
            for expected in ["明日n", "明日", "あし"] {
                try engine.handle(.backspace)
                #expect(try engine.markedText().text == expected)
            }
            try engine.handle(.insert("ta"))
            #expect(try engine.markedText().text == "明日")
            try engine.handle(.backspace)
            try engine.handle(.insert("."))
            #expect(try engine.markedText().text == "足。")
            engine.cancel()
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
